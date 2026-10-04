#if os(macOS)
import AppKit
import FileProvider
import os

/// Manages the Finder drives: one File Provider domain per bucket the user turns on.
///
/// The extension can't read the app's Keychain item, so the app hands each drive its
/// credentials over the extension's XPC control service whenever they change.
///
/// macOS adds new drives switched off; the user approves each one once in System Settings.
@MainActor
@Observable
final class FinderDriveManager {
    private(set) var enabledIDs: Set<UUID> = []
    private(set) var pendingIDs: Set<UUID> = []
    /// Drives that are added but still switched off in System Settings.
    private(set) var awaitingApprovalIDs: Set<UUID> = []
    private(set) var errors: [UUID: String] = [:]
    /// Bytes each drive's downloads take on this Mac, as last measured.
    private(set) var downloadedBytes: [UUID: Int64] = [:]
    private(set) var removingDownloadsIDs: Set<UUID> = []

    @ObservationIgnored private var domains: [UUID: NSFileProviderDomain] = [:]
    @ObservationIgnored private var credentialsByID: [UUID: R2Credentials] = [:]
    @ObservationIgnored private var revealWhenApproved: Set<UUID> = []
    @ObservationIgnored private var pendingRefreshes: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var domainObserver: NSObjectProtocol?
    @ObservationIgnored private let logger = Logger(subsystem: "fiaxe.Fiaxe", category: "FinderDrive")

    /// How often open drives are asked to look for changes made outside this Mac.
    private static let pollInterval: Duration = .seconds(60)

    init() {
        domainObserver = NotificationCenter.default.addObserver(
            forName: .fileProviderDomainDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshApprovalState() }
        }
    }

    func isEnabled(_ credentialsID: UUID) -> Bool {
        enabledIDs.contains(credentialsID)
    }

    /// Opens System Settings › General › Login Items & Extensions, where File Provider
    /// extensions are switched on.
    func openExtensionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Domains

    /// Brings the registered drives in line with the saved connections: recreates drives whose
    /// connection now points at a different bucket, updates names, and re-sends credentials.
    ///
    /// Drives are never removed here, only by `setEnabled(false:)` or `removeDrive(for:)`, so a
    /// connection list that failed to load can't wipe them out.
    func sync(with credentialsList: [R2Credentials]) async {
        let registered: [NSFileProviderDomain]
        do {
            registered = try await NSFileProviderManager.domains()
        } catch {
            logger.error("Listing Finder drives failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        for domain in registered {
            guard let id = UUID(uuidString: domain.identifier.rawValue) else { continue }
            guard let credentials = credentialsList.first(where: { $0.id == id }) else {
                domains[id] = domain
                continue
            }
            credentialsByID[id] = credentials

            let identity = Self.identity(of: credentials)
            var active = domain
            if let previous = domain.userInfo?[FinderDrive.bucketIdentityKey] as? String, previous != identity {
                // The connection now points at another bucket: start that drive from scratch.
                await remove(domain)
                active = Self.makeDomain(for: credentials)
                try? await NSFileProviderManager.add(active)
            } else if domain.displayName != credentials.bucketName || domain.userInfo?[FinderDrive.bucketIdentityKey] == nil {
                active = Self.makeDomain(for: credentials)
                try? await NSFileProviderManager.add(active)
            }
            domains[id] = active
        }

        enabledIDs = Set(domains.keys)
        await refreshApprovalState()
        for id in domains.keys {
            if let credentials = credentialsByID[id] {
                await sendCredentials(credentials)
            }
        }
        updatePolling()
    }

    func setEnabled(_ enabled: Bool, for credentials: R2Credentials) async {
        let id = credentials.id
        pendingIDs.insert(id)
        errors[id] = nil
        defer { pendingIDs.remove(id) }

        guard enabled else {
            await removeDrive(for: id)
            return
        }

        let domain = Self.makeDomain(for: credentials)
        do {
            try await NSFileProviderManager.add(domain)
        } catch {
            errors[id] = "Couldn't add the drive: \(error.localizedDescription)"
            return
        }
        domains[id] = domain
        credentialsByID[id] = credentials
        enabledIDs.insert(id)
        updatePolling()

        await refreshApprovalState()
        if awaitingApprovalIDs.contains(id) {
            revealWhenApproved.insert(id)
            openExtensionSettings()
            await sendCredentials(credentials)
        } else {
            await sendCredentials(credentials)
            await reveal(domain, id: id)
        }
    }

    /// Removes a bucket's drive, e.g. when its connection is deleted.
    func removeDrive(for credentialsID: UUID) async {
        guard let domain = domains[credentialsID] else { return }
        await remove(domain)
        domains[credentialsID] = nil
        credentialsByID[credentialsID] = nil
        enabledIDs.remove(credentialsID)
        awaitingApprovalIDs.remove(credentialsID)
        revealWhenApproved.remove(credentialsID)
        errors[credentialsID] = nil
        downloadedBytes[credentialsID] = nil
        updatePolling()
    }

    /// Opens the drive's root folder in Finder.
    func reveal(_ credentials: R2Credentials) async {
        guard let domain = domains[credentials.id] else { return }
        await reveal(domain, id: credentials.id)
    }

    private func reveal(_ domain: NSFileProviderDomain, id: UUID) async {
        guard let manager = NSFileProviderManager(for: domain) else { return }
        do {
            let url = try await manager.getUserVisibleURL(for: .rootContainer)
            NSWorkspace.shared.open(url)
        } catch {
            errors[id] = "Couldn't open the drive: \(error.localizedDescription)"
        }
    }

    // MARK: - Downloads on this Mac

    /// Measures how much of the drive is downloaded on this Mac.
    func refreshDownloadedBytes(for credentials: R2Credentials) async {
        guard let root = await rootURL(for: credentials.id) else { return }
        downloadedBytes[credentials.id] = await Task.detached {
            DriveStorage.downloadedFiles(under: root).reduce(0) { $0 + $1.bytes }
        }.value
    }

    /// Removes the local copies of everything downloaded from the drive, like Finder's
    /// "Remove Download". Files stay in the bucket. Items set to Keep Downloaded, and changes
    /// not uploaded yet, stay on this Mac.
    func removeDownloads(for credentials: R2Credentials) async {
        let id = credentials.id
        guard !removingDownloadsIDs.contains(id), let root = await rootURL(for: id) else { return }
        removingDownloadsIDs.insert(id)
        await Task.detached {
            for file in DriveStorage.downloadedFiles(under: root) {
                try? FileManager.default.evictUbiquitousItem(at: file.url)
            }
        }.value
        removingDownloadsIDs.remove(id)
        await refreshDownloadedBytes(for: credentials)
    }

    private func rootURL(for credentialsID: UUID) async -> URL? {
        guard let domain = domains[credentialsID], let manager = NSFileProviderManager(for: domain) else { return nil }
        return try? await manager.getUserVisibleURL(for: .rootContainer)
    }

    /// Asks the drive to pick up changes the app just made to the bucket. Bursts (e.g. a batch
    /// upload) are coalesced into one refresh of the folders open in Finder.
    func bucketDidChange(_ credentialsID: UUID) {
        guard let domain = domains[credentialsID] else { return }
        pendingRefreshes[credentialsID]?.cancel()
        pendingRefreshes[credentialsID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            self.pendingRefreshes[credentialsID] = nil
            do {
                try await self.withControlService(of: domain) { proxy, done in
                    proxy.refresh(reply: done)
                }
            } catch {
                try? await NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet)
            }
        }
    }

    /// Re-reads which drives the user has approved. A newly approved drive gets its
    /// credentials again and, if the user was turning it on, opens in Finder.
    private func refreshApprovalState() async {
        guard let registered = try? await NSFileProviderManager.domains() else { return }
        let waiting = Set(registered.compactMap { domain -> UUID? in
            guard let id = UUID(uuidString: domain.identifier.rawValue), domains[id] != nil, !domain.userEnabled else { return nil }
            return id
        })
        let approved = awaitingApprovalIDs.subtracting(waiting)
        awaitingApprovalIDs = waiting
        for id in approved {
            if let credentials = credentialsByID[id] {
                await sendCredentials(credentials)
            }
            if revealWhenApproved.remove(id) != nil, let domain = domains[id] {
                await reveal(domain, id: id)
            }
        }
    }

    private func remove(_ domain: NSFileProviderDomain) async {
        do {
            // Keeps any edits that hadn't finished uploading.
            if let preserved = try await NSFileProviderManager.remove(domain, mode: .preserveDirtyUserData) {
                logger.info("Unsynced drive changes preserved at \(preserved.path, privacy: .private)")
                NSWorkspace.shared.activateFileViewerSelecting([preserved])
            }
        } catch {
            logger.error("Removing Finder drive failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Credentials hand-off

    /// Sends credentials to the drive's extension, retrying while the extension starts up.
    private func sendCredentials(_ credentials: R2Credentials) async {
        guard let domain = domains[credentials.id],
              let payload = try? JSONEncoder().encode(credentials) else { return }

        var lastError: Error?
        for attempt in 0..<4 {
            do {
                try await withControlService(of: domain) { proxy, done in
                    proxy.updateCredentials(payload, reply: done)
                }
                errors[credentials.id] = nil
                return
            } catch {
                lastError = error
                try? await Task.sleep(for: .seconds(attempt + 1))
            }
        }
        let message = lastError?.localizedDescription ?? "unknown error"
        logger.error("Sending credentials to Finder drive failed: \(message, privacy: .public)")
        errors[credentials.id] = "Couldn't connect to the Finder drive: \(message)"
    }

    /// Connects to the extension's control service and runs one call on it.
    private func withControlService(
        of domain: NSFileProviderDomain,
        _ call: @escaping (FinderDriveControlProtocol, @escaping (NSError?) -> Void) -> Void
    ) async throws {
        guard let manager = NSFileProviderManager(for: domain) else {
            throw NSFileProviderError(.providerNotFound)
        }
        guard let service = try await manager.service(named: FinderDrive.controlServiceName, for: .rootContainer) else {
            throw NSFileProviderError(.providerNotFound)
        }
        let connection = try await service.fileProviderConnection()
        connection.remoteObjectInterface = NSXPCInterface(with: FinderDriveControlProtocol.self)
        connection.resume()
        defer { connection.invalidate() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.resume(throwing: error)
            }
            guard let proxy = proxy as? FinderDriveControlProtocol else {
                once.resume(throwing: NSFileProviderError(.providerNotFound))
                return
            }
            call(proxy) { error in
                if let error { once.resume(throwing: error) } else { once.resume() }
            }
        }
    }

    // MARK: - Polling

    /// While any drive is on, periodically signal it so it re-lists the folders open in Finder.
    /// Credentials are re-sent each time too (the extension ignores unchanged ones), so a drive
    /// process that started without them recovers within a minute.
    private func updatePolling() {
        if domains.isEmpty {
            pollTask?.cancel()
            pollTask = nil
            return
        }
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard let self, !Task.isCancelled else { return }
                for (id, domain) in self.domains {
                    if let credentials = self.credentialsByID[id],
                       let payload = try? JSONEncoder().encode(credentials) {
                        try? await self.withControlService(of: domain) { proxy, done in
                            proxy.updateCredentials(payload, reply: done)
                        }
                    }
                    try? await NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet)
                }
            }
        }
    }

    // MARK: - Helpers

    private static func makeDomain(for credentials: R2Credentials) -> NSFileProviderDomain {
        let domain = NSFileProviderDomain(identifier: FinderDrive.domainIdentifier(for: credentials.id),
                                          displayName: credentials.bucketName)
        domain.userInfo = [FinderDrive.bucketIdentityKey: identity(of: credentials)]
        return domain
    }

    private static func identity(of credentials: R2Credentials) -> String {
        FinderDrive.bucketIdentity(of: credentials)
    }
}

/// Finds the downloaded files in a drive's folder.
nonisolated enum DriveStorage {
    /// Files with local content under `root`. Folders that were never opened (dataless) are
    /// skipped without being read, so measuring doesn't make macOS list them from R2.
    static func downloadedFiles(under root: URL) -> [(url: URL, bytes: Int64)] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .totalFileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        var files: [(url: URL, bytes: Int64)] = []
        for case let url as URL in enumerator {
            if isDataless(url) {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isDirectory != true,
                  url.lastPathComponent != ".DS_Store",
                  let bytes = values.totalFileAllocatedSize, bytes > 0 else { continue }
            files.append((url, Int64(bytes)))
        }
        return files
    }

    private static func isDataless(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_flags & UInt32(SF_DATALESS) != 0
    }
}

/// Resumes a continuation at most once, whichever XPC callback fires first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume() {
        take()?.resume()
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<Void, Error>? {
        lock.withLock {
            defer { continuation = nil }
            return continuation
        }
    }
}
#endif
