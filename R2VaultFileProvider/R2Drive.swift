import FileProvider
import CryptoKit
import UniformTypeIdentifiers
import os

/// The drive behind one File Provider domain (one R2 bucket).
///
/// Holds the bucket credentials pushed by the app, the item database, and the logic that turns
/// File Provider callbacks into R2 requests. One instance per extension instance.
final class R2Drive: @unchecked Sendable {
    let domainIdentifier: String
    let manager: NSFileProviderManager?
    let controlService = DriveControlService()

    private let logger = Logger(subsystem: "fiaxe.Fiaxe.FileProvider", category: "drive")
    private let baseDirectory: URL
    private let session: URLSession
    private let expectedIdentity: String?
    private let backingStore: String
    private let lock = NSLock()
    private var state: (credentials: R2Credentials, database: ItemDatabase)?
    private var invalidated = false
    private var openFolders: [String: Int] = [:]
    private var isRefreshing = false
    private var streams: [String: ReadStream] = [:]
    /// Bytes of downloads in flight, which the volume's free space doesn't reflect yet.
    private var claimedDownloadBytes: Int64 = 0

    /// Downloads fail rather than leave less than this free on the Mac.
    static let minimumFreeSpace: Int64 = 2_000_000_000
    /// Free bytes on the volume holding `url`. Tests replace it.
    var measureFreeSpace: @Sendable (URL) -> Int64? = { url in
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity).map(Int64.init)
    }

    /// Keys held by local operations in flight.
    private var heldKeys: [UUID: [String]] = [:]
    /// Keys recently changed by local operations, with the generation at which they finished.
    private var recentChanges: [(key: String, generation: UInt64, date: Date)] = []
    private var generation: UInt64 = 0

    /// Folders open in Finder are re-listed this often when the working set is signalled.
    private let openFolderRefreshInterval: TimeInterval = 45
    /// Other folders the system has seen are re-listed this often, a few at a time.
    private let backgroundRefreshInterval: TimeInterval = 30 * 60
    private let trashPurgeInterval: TimeInterval = 6 * 60 * 60

    init(domain: NSFileProviderDomain, configuration: URLSessionConfiguration = .default) {
        domainIdentifier = domain.identifier.rawValue
        manager = NSFileProviderManager(for: domain)
        expectedIdentity = domain.userInfo?[FinderDrive.bucketIdentityKey] as? String
        backingStore = domain.backingStoreIdentity.map { SHA256.hash(data: $0).prefix(8).map { String(format: "%02x", $0) }.joined() } ?? ""

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let safeName = domainIdentifier.replacingOccurrences(of: "/", with: "_")
        baseDirectory = support.appendingPathComponent("R2VaultDrive", isDirectory: true)
            .appendingPathComponent(safeName, isDirectory: true)

        configuration.timeoutIntervalForRequest = 60
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)

        controlService.drive = self
        if let saved = loadSavedCredentials(), expectedIdentity == nil || Self.identity(of: saved) == expectedIdentity {
            try? activate(saved)
            signalWorkingSet()
        }
    }

    /// Stops in-flight requests. The session is deliberately not invalidated: creating a task
    /// on an invalidated session raises an exception, and late work may still try.
    func invalidate() {
        lock.withLock { invalidated = true }
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
    }

    private var isInvalidated: Bool {
        lock.withLock { invalidated }
    }

    // MARK: - Credentials

    private static func identity(of credentials: R2Credentials) -> String {
        FinderDrive.bucketIdentity(of: credentials)
    }

    private var credentialsURL: URL {
        baseDirectory.appendingPathComponent("credentials.json")
    }

    private func loadSavedCredentials() -> R2Credentials? {
        guard let data = try? Data(contentsOf: credentialsURL) else { return nil }
        return try? JSONDecoder().decode(R2Credentials.self, from: data)
    }

    /// Called by the app (over XPC) whenever the bucket's credentials are saved.
    func setCredentials(_ credentials: R2Credentials) throws {
        if let expectedIdentity, Self.identity(of: credentials) != expectedIdentity {
            throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.Code.featureUnsupported.rawValue,
                          userInfo: [NSLocalizedDescriptionKey: "These credentials are for a different bucket than this drive."])
        }
        let previous = lock.withLock { state?.credentials }
        guard previous != credentials else { return }

        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(credentials)
        try data.write(to: credentialsURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credentialsURL.path)

        try activate(credentials)
        logger.info("Credentials updated for bucket \(credentials.bucketName, privacy: .public)")

        manager?.signalErrorResolved(NSFileProviderError(.notAuthenticated)) { _ in }
        manager?.signalErrorResolved(NSFileProviderError(.serverUnreachable)) { _ in }
        signalWorkingSet()
    }

    /// Opens the item database. Each account/bucket pair, and each rebuild of the system's
    /// copy of the domain, gets its own database, so the drive never mixes up old state.
    private func activate(_ credentials: R2Credentials) throws {
        let identity = Self.identity(of: credentials) + "#" + backingStore
        let digest = SHA256.hash(data: Data(identity.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let url = baseDirectory.appendingPathComponent(digest, isDirectory: true).appendingPathComponent("items.sqlite")

        let current = lock.withLock { state }
        let database: ItemDatabase
        if let current, Self.identity(of: current.credentials) == Self.identity(of: credentials) {
            database = current.database
        } else {
            database = try ItemDatabase(url: url, rootID: ItemDatabase.rootID, trashID: ItemDatabase.trashID,
                                        trashKey: FinderDrive.trashPrefix)
        }
        lock.withLock { state = (credentials, database) }
    }

    /// The client and database, or `notAuthenticated` until the app has provided credentials.
    func context() throws -> (client: R2Client, database: ItemDatabase) {
        let (state, invalidated) = lock.withLock { (state, invalidated) }
        if invalidated { throw CocoaError(.userCancelled) }
        guard let state else { throw NSFileProviderError(.notAuthenticated) }
        return (R2Client(credentials: state.credentials, session: session), state.database)
    }

    // MARK: - Signalling

    func signalWorkingSet() {
        manager?.signalEnumerator(for: .workingSet) { _ in }
    }

    func syncAnchor(for seq: Int64, database: ItemDatabase) -> NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor(Data("\(database.epoch):\(seq)".utf8))
    }

    /// The seq encoded in an anchor, or nil if the anchor came from a different database.
    func seq(from anchor: NSFileProviderSyncAnchor, database: ItemDatabase) -> Int64? {
        guard let text = String(data: anchor.rawValue, encoding: .utf8) else { return nil }
        let parts = text.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, String(parts[0]) == database.epoch else { return nil }
        return Int64(parts[1])
    }

    // MARK: - Local operations vs. listings

    /// True if `held` is `key`, or a folder key containing it. Compared as bytes, like S3.
    private static func covers(_ held: String, _ key: String) -> Bool {
        ItemDatabase.sameBytes(held, key) || (held.hasSuffix("/") && key.utf8.starts(with: held.utf8))
    }

    /// Runs `body` while holding `keys`. Operations on overlapping keys (the same key, or keys
    /// inside a folder being changed) run one after another. When `body` finishes, the keys are
    /// recorded as changed so that listings fetched before then don't undo the change.
    private func withKeys<T>(_ keys: [String], _ body: () async throws -> T) async throws -> T {
        let token = UUID()
        while true {
            try Task.checkCancellation()
            let acquired = lock.withLock { () -> Bool in
                let conflict = heldKeys.values.contains { held in
                    held.contains { h in keys.contains { Self.covers(h, $0) || Self.covers($0, h) } }
                }
                if conflict { return false }
                heldKeys[token] = keys
                return true
            }
            if acquired { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        defer {
            lock.withLock {
                heldKeys[token] = nil
                generation += 1
                let now = Date()
                recentChanges.removeAll { now.timeIntervalSince($0.date) > 600 }
                for key in keys { recentChanges.append((key, generation, now)) }
            }
        }
        return try await body()
    }

    private var currentGeneration: UInt64 {
        lock.withLock { generation }
    }

    /// Whether a local operation is changing `key`, or finished changing it after `start`.
    private func touchedLocally(_ key: String, since start: UInt64) -> Bool {
        lock.withLock {
            heldKeys.values.contains { $0.contains { Self.covers($0, key) } }
                || recentChanges.contains { $0.generation > start && Self.covers($0.key, key) }
        }
    }

    func folderOpened(_ id: String) {
        lock.withLock { openFolders[id, default: 0] += 1 }
    }

    func folderClosed(_ id: String) {
        lock.withLock {
            openFolders[id, default: 1] -= 1
            if openFolders[id] == 0 { openFolders[id] = nil }
        }
    }

    // MARK: - Lookup

    func item(for id: String) throws -> FileProviderItem {
        if id == ItemDatabase.rootID { return FileProviderItem.rootItem() }
        let (_, database) = try context()
        guard let record = database.record(id: id) else { throw NSFileProviderError(.noSuchItem) }
        return FileProviderItem(record)
    }

    // MARK: - Listing

    /// Lists a folder from R2, records the result, and returns the folder's children.
    func listFolder(id: String) async throws -> [ItemRecord] {
        let (client, database) = try context()
        if id == ItemDatabase.trashID {
            await purgeTrashIfDue(client: client, database: database)
        }
        return try await refresh(folderID: id, client: client, database: database)
    }

    @discardableResult
    private func refresh(folderID: String, client: R2Client, database: ItemDatabase) async throws -> [ItemRecord] {
        // A folder moved while being listed is listed again at its new key.
        for _ in 0..<3 {
            guard let folder = database.record(id: folderID), folder.isFolder else {
                throw NSFileProviderError(.noSuchItem)
            }
            let startedAt = Date()
            let startGeneration = currentGeneration
            let listing = try await client.list(prefix: folder.key)
            logger.info("Listed folder: \(listing.objects.count + listing.prefixes.count, privacy: .public) entries in \(Self.elapsed(since: startedAt), privacy: .public)")

            var entries: [ServerEntry] = []
            for prefix in listing.prefixes {
                if folder.id == ItemDatabase.rootID && prefix == FinderDrive.trashPrefix { continue }
                guard let name = Self.childName(of: prefix, under: folder.key), !Self.isExcluded(name) else { continue }
                entries.append(ServerEntry(key: prefix, name: name, isFolder: true, size: 0, etag: "", modified: nil))
            }
            for object in listing.objects {
                guard !ItemDatabase.sameBytes(object.key, folder.key), !object.key.hasSuffix("/"),
                      let name = Self.childName(of: object.key, under: folder.key), !Self.isExcluded(name) else { continue }
                entries.append(ServerEntry(key: object.key, name: name, isFolder: false, size: object.size,
                                           etag: object.etag, modified: object.lastModified))
            }

            guard let result = database.reconcile(
                folderID: folder.id, listedKey: folder.key, startedAt: startedAt, entries: entries,
                isBusy: { self.touchedLocally($0, since: startGeneration) }
            ) else { continue }
            if result.changed {
                signalWorkingSet()
            }
            return result.children
        }
        throw NSFileProviderError(.serverUnreachable)
    }

    /// Re-lists folders so remote changes reach Finder. Folders open in Finder are refreshed
    /// often; everything else the system has seen is refreshed slowly, a few folders per pass.
    /// `openOnly` limits the pass to open folders (used after the app itself changes the bucket).
    func refreshStaleFolders(force: Bool = false, openOnly: Bool = false) async {
        guard let (client, database) = try? context() else { return }
        let claimed = lock.withLock { () -> Bool in
            if isRefreshing { return false }
            isRefreshing = true
            return true
        }
        guard claimed else { return }
        defer { lock.withLock { isRefreshing = false } }

        let now = Date()
        let open = lock.withLock { Array(openFolders.keys) }
        var folderIDs = open.filter { id in
            guard let listed = database.lastListed(folderID: id) else { return false }
            return force || now.timeIntervalSince(listed) >= openFolderRefreshInterval
        }
        if !openOnly {
            let cutoff = force ? now : now.addingTimeInterval(-backgroundRefreshInterval)
            for folder in database.listedFolders(refreshedBefore: cutoff, limit: 10) where !folderIDs.contains(folder.id) {
                folderIDs.append(folder.id)
            }
        }

        for id in folderIDs {
            if isInvalidated || Task.isCancelled { return }
            do {
                try await refresh(folderID: id, client: client, database: database)
            } catch {
                if Self.isCancellation(error) { return }
                logger.error("Folder refresh failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if !openOnly {
            await purgeTrashIfDue(client: client, database: database)
        }
    }

    /// Unfinished uploads R2 keeps for about a week; ones the system never retried (the file
    /// was deleted, say) are aborted after that so their parts don't linger.
    private func abortAbandonedUploads(client: R2Client, database: ItemDatabase) async {
        for upload in database.pendingUploads(startedBefore: Date().addingTimeInterval(-7 * 24 * 60 * 60)) {
            do {
                try await client.abortMultipartUpload(key: upload.key, uploadID: upload.uploadID)
                database.finishUpload(key: upload.key)
            } catch R2Client.ClientError.http(_, "NoSuchUpload", _) {
                database.finishUpload(key: upload.key)
            } catch {
                // Try again at the next purge.
            }
        }
    }

    // MARK: - Trash

    /// Deletes Trash entries that have been there longer than the retention period.
    /// An entry's age is the newest LastModified among its objects, i.e. when it was moved there.
    private func purgeTrashIfDue(client: R2Client, database: ItemDatabase) async {
        let now = Date()
        if let last = database.dateValue("lastTrashPurge"), now.timeIntervalSince(last) < trashPurgeInterval {
            return
        }
        database.setDateValue("lastTrashPurge", now)
        await abortAbandonedUploads(client: client, database: database)

        do {
            let listing = try await client.list(prefix: FinderDrive.trashPrefix, delimiter: nil)
            var entries: [String: (newest: Date, keys: [String], isFolder: Bool)] = [:]
            for object in listing.objects {
                let relative = String(String.UnicodeScalarView(
                    object.key.unicodeScalars.dropFirst(FinderDrive.trashPrefix.unicodeScalars.count)))
                guard let top = relative.split(separator: "/", omittingEmptySubsequences: false).first,
                      !top.isEmpty else { continue }
                let name = String(top)
                var entry = entries[name] ?? (.distantPast, [], relative.contains("/"))
                entry.newest = max(entry.newest, object.lastModified ?? now)
                entry.keys.append(object.key)
                entries[name] = entry
            }

            let cutoff = now.addingTimeInterval(-Double(FinderDrive.trashRetentionDays) * 24 * 60 * 60)
            var purged = false
            for (name, entry) in entries where entry.newest < cutoff {
                let key = FinderDrive.trashPrefix + name + (entry.isFolder ? "/" : "")
                try await withKeys([key]) {
                    try await Self.forEach(entry.keys, concurrency: 8) { try await client.delete(key: $0) }
                    if let record = database.record(key: key) {
                        database.remove(id: record.id)
                    }
                }
                purged = true
            }
            if purged {
                signalWorkingSet()
            }
        } catch {
            logger.error("Trash purge failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A free name in a folder: "name", then "name 2", "name 3", ... (or with `suffix` first).
    private func uniqueName(for name: String, in parentKey: String, isFolder: Bool, suffix: String? = nil,
                            client: R2Client, database: ItemDatabase) async throws -> String {
        let ext = isFolder ? "" : (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        let base = suffix.map { "\(stem) \($0)" } ?? stem
        for attempt in 1...50 {
            var candidate = attempt == 1 ? base : "\(base) \(attempt)"
            if !ext.isEmpty { candidate += ".\(ext)" }
            let key = parentKey + candidate + (isFolder ? "/" : "")
            if database.record(key: key) != nil { continue }
            let taken = isFolder ? try await client.prefixExists(key) : try await client.head(key: key) != nil
            if !taken { return candidate }
        }
        return "\(base) \(UUID().uuidString.prefix(8))" + (ext.isEmpty ? "" : ".\(ext)")
    }

    // MARK: - Downloads

    /// Most parallel connections used for one download. Ranges are only split into parts of at
    /// least 4 MB, so small reads stay a single request and large ones fill the line.
    static let downloadConnections = 8

    func fetchContents(id: String, progress: Progress) async throws -> (URL, FileProviderItem) {
        let (client, database) = try context()
        guard let record = database.record(id: id), !record.isFolder else {
            throw NSFileProviderError(.noSuchItem)
        }
        progress.totalUnitCount = max(record.size, 1)

        let started = Date()
        let (file, info) = try await download(record, range: 0..<record.size, ifMatch: nil, client: client, progress: progress)
        logger.info("Full download: \(Self.throughput(record.size, since: started), privacy: .public)")
        let updated = applyServerInfo(info, to: record, database: database)
        return (file, FileProviderItem(updated))
    }

    /// Fetches the part of a file an app is reading. How much is fetched, and how far ahead
    /// the drive reads, adapts to the access pattern: see `planRead`.
    func fetchPartialContents(
        id: String,
        version: NSFileProviderItemVersion,
        minimalRange: NSRange,
        alignment: Int,
        strictVersioning: Bool,
        progress: Progress
    ) async throws -> (URL, FileProviderItem, NSRange) {
        let (client, database) = try context()
        guard var record = database.record(id: id), !record.isFolder else {
            throw NSFileProviderError(.noSuchItem)
        }
        var requestedETag = String(data: version.contentVersion, encoding: .utf8) ?? record.etag
        if requestedETag.isEmpty { requestedETag = record.etag }

        let isMedia = UTType(filenameExtension: (record.name as NSString).pathExtension)?.conforms(to: .audiovisualContent) ?? false
        let plan = planRead(id: id, etag: requestedETag, location: Int64(minimalRange.location), isMedia: isMedia,
                            fileSize: record.size)
        var range = Self.fetchRange(covering: minimalRange, alignment: alignment, fileSize: record.size, chunk: plan.chunk)
        guard !range.isEmpty else {
            let empty = try makeProviderTemporaryFile()
            return (empty, FileProviderItem(record), NSRange(location: 0, length: 0))
        }
        progress.totalUnitCount = range.upperBound - range.lowerBound
        let started = Date()
        if let tail = plan.tail, let manager {
            let nsRange = NSRange(location: Int(tail.lowerBound), length: Int(tail.upperBound - tail.lowerBound))
            manager.requestDownloadForItem(withIdentifier: NSFileProviderItemIdentifier(id), requestedRange: nsRange) { _ in }
        }
        if range.upperBound < record.size {
            readAhead(id: id, after: range, fileSize: record.size)
        }

        var downloaded: (file: URL, info: R2Client.ObjectInfo)
        do {
            downloaded = try await download(record, range: range, ifMatch: requestedETag, client: client, progress: progress)
        } catch R2Client.ClientError.http(let status, _, _) where status == 412 {
            // The object changed since the system last saw it.
            if strictVersioning { throw NSFileProviderError(.versionNoLongerAvailable) }
            guard let info = try await client.head(key: record.key) else { throw NSFileProviderError(.noSuchItem) }
            record = applyServerInfo(info, to: record, database: database)
            range = Self.fetchRange(covering: minimalRange, alignment: alignment, fileSize: record.size, chunk: plan.chunk)
            guard !range.isEmpty else {
                let empty = try makeProviderTemporaryFile()
                return (empty, FileProviderItem(record), NSRange(location: 0, length: 0))
            }
            downloaded = try await download(record, range: range, ifMatch: record.etag, client: client, progress: progress)
        }
        record = applyServerInfo(downloaded.info, to: record, database: database)

        let kind = plan.isReadAhead ? "Read-ahead" : "Read"
        logger.info("\(kind, privacy: .public) @\(range.lowerBound / 1_048_576, privacy: .public) MB: \(Self.throughput(range.upperBound - range.lowerBound, since: started), privacy: .public)")
        let fetched = NSRange(location: Int(range.lowerBound), length: Int(range.upperBound - range.lowerBound))
        return (downloaded.file, FileProviderItem(record), fetched)
    }

    /// Downloads `range` into a new file in the provider's temporary directory, with the bytes
    /// at their real offsets (the rest of the file is sparse), over parallel connections.
    private func download(_ record: ItemRecord, range: Range<Int64>, ifMatch: String?, client: R2Client,
                          progress: Progress) async throws -> (file: URL, info: R2Client.ObjectInfo) {
        let bytes = range.upperBound - range.lowerBound
        try claimSpace(bytes, for: record)
        defer { lock.withLock { claimedDownloadBytes -= bytes } }
        let output = try makeProviderTemporaryFile()
        do {
            let handle = try FileHandle(forWritingTo: output)
            try handle.truncate(atOffset: UInt64(range.upperBound))
            try handle.close()
            let info = try await client.download(key: record.key, range: range, ifMatch: ifMatch, into: output,
                                                 connections: Self.downloadConnections, progress: progress)
            return (output, info)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    /// Reserves room for a download, or throws if it would leave less than `minimumFreeSpace`
    /// free. Without this, "Download Now" on the drive fills the disk.
    private func claimSpace(_ bytes: Int64, for record: ItemRecord) throws {
        let free = measureFreeSpace(try providerTemporaryDirectory())
        try lock.withLock {
            if let free, free - claimedDownloadBytes - bytes < Self.minimumFreeSpace {
                throw Self.notEnoughSpaceError(downloading: record.name, bytes: bytes)
            }
            claimedDownloadBytes += bytes
        }
    }

    static func notEnoughSpaceError(downloading name: String, bytes: Int64) -> Error {
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        let reserve = ByteCountFormatter.string(fromByteCount: minimumFreeSpace, countStyle: .file)
        return CocoaError(.fileWriteOutOfSpace, userInfo: [
            NSLocalizedDescriptionKey: "There isn\u{2019}t enough space on this Mac to download \u{201C}\(name)\u{201D} (\(size)).",
            NSLocalizedRecoverySuggestionErrorKey: "R2Vault keeps at least \(reserve) free. Remove downloads from the drive or free up space, then try again.",
        ])
    }

    // MARK: - Keep Downloaded

    /// Finder's Keep Downloaded actions. The system downloads kept items (and folder contents)
    /// right away and never evicts them; turning it off makes them evictable again.
    func setKeepDownloaded(_ keep: Bool, ids: [String]) throws {
        let (_, database) = try context()
        let eligible = ids.filter { id in
            guard id != ItemDatabase.rootID, id != ItemDatabase.trashID, let record = database.record(id: id) else { return false }
            return !record.key.hasPrefix(FinderDrive.trashPrefix)
        }
        if !database.setKeepDownloaded(keep, ids: eligible).isEmpty {
            signalWorkingSet()
        }
    }

    // MARK: - Read-ahead

    /// How one open file is being read.
    private struct ReadStream {
        var etag: String
        /// Where the reader last needed data that wasn't on disk.
        var anchor: Int64
        /// End of everything fetched or requested so far.
        var frontier: Int64
        /// Size of the next read-ahead chunk. Starts small so the next piece arrives quickly,
        /// then doubles so throughput grows.
        var nextChunk: Int64
        /// How far past `anchor` the drive may read ahead.
        var window: Int64
        /// Read-ahead ranges requested from the system but not fetched yet.
        var pending: [(range: Range<Int64>, requestedAt: Date)]
        /// Requests left over from before the reader jumped elsewhere.
        var stale: [Range<Int64>]
        var lastUsed: Date
    }

    /// What a reader waits for when it opens a file or seeks: small, so it gets going quickly.
    private static let firstFetch: Int64 = 1024 * 1024
    /// Players probe a video's header and first seconds before starting, each probe a separate
    /// round trip, so media gets a bigger first fetch (and bigger still from the start).
    private static let mediaSeekFetch: Int64 = 4 * 1024 * 1024
    private static let mediaOpenFetch: Int64 = 8 * 1024 * 1024
    /// MP4/MOV files often keep their index at the end, which players read before starting.
    private static let mediaTail: Int64 = 2 * 1024 * 1024
    /// What a reader waits for when it outruns the read-ahead.
    private static let catchUpFetch: Int64 = 2 * 1024 * 1024
    private static let firstChunk: Int64 = 2 * 1024 * 1024
    private static let maximumChunk: Int64 = 32 * 1024 * 1024
    /// Read-ahead allowed past the reader: generous for audio/video, which is usually played
    /// through, small for everything else, and doubled whenever the reader catches up.
    private static let mediaWindow: Int64 = 64 * 1024 * 1024
    private static let otherWindow: Int64 = 16 * 1024 * 1024
    private static let maximumWindow: Int64 = 1024 * 1024 * 1024
    /// Read-ahead downloads in flight per file and across all files, so peeking at files can't
    /// starve the one being watched.
    private static let readAheadPerFile = 3
    private static let maximumReadAhead = 4

    /// Decides how much to fetch for a read at `location`.
    ///
    /// The system fetches only what a reader hits that isn't on disk, and doesn't tell the
    /// extension about reads of data that is, so the drive reads ahead itself. Read-ahead starts
    /// alongside the reader's first fetch and stays a window ahead of where the reader last
    /// needed data. A reader that catches up (it consumes faster than expected) doubles the
    /// window. A jump elsewhere (a seek) starts over with a small first fetch, which keeps opening
    /// files and seeking quick.
    private func planRead(id: String, etag: String, location: Int64, isMedia: Bool,
                          fileSize: Int64) -> (chunk: Int64, isReadAhead: Bool, tail: Range<Int64>?) {
        lock.withLock {
            let now = Date()
            streams = streams.filter { now.timeIntervalSince($0.value.lastUsed) < 300 }
            let window = isMedia ? Self.mediaWindow : Self.otherWindow
            let firstChunk = isMedia ? 8 * 1024 * 1024 : Self.firstChunk
            let seekFetch = isMedia ? Self.mediaSeekFetch : Self.firstFetch

            guard var stream = streams[id], stream.etag == etag else {
                var stream = ReadStream(etag: etag, anchor: location, frontier: location, nextChunk: firstChunk,
                                        window: window, pending: [], stale: [], lastUsed: now)
                var tail: Range<Int64>?
                if isMedia && location < Self.mediaOpenFetch && fileSize > 4 * Self.mediaOpenFetch {
                    let start = (fileSize - Self.mediaTail) / (1024 * 1024) * (1024 * 1024)
                    tail = start..<fileSize
                    stream.pending.append((start..<fileSize, now))
                }
                streams[id] = stream
                return (isMedia && location < Self.mediaOpenFetch ? Self.mediaOpenFetch : seekFetch, false, tail)
            }
            stream.lastUsed = now
            stream.pending.removeAll { now.timeIntervalSince($0.requestedAt) > 120 }

            if let index = stream.pending.firstIndex(where: { $0.range.contains(location) }) {
                let range = stream.pending.remove(at: index).range
                streams[id] = stream
                return (range.upperBound - range.lowerBound, true, nil)
            }
            if let index = stream.stale.firstIndex(where: { $0.contains(location) }) {
                let range = stream.stale.remove(at: index)
                streams[id] = stream
                return (range.upperBound - range.lowerBound, true, nil)
            }

            if location >= stream.anchor && location <= stream.frontier + stream.nextChunk {
                stream.window = min(stream.window * 2, Self.maximumWindow)
                stream.anchor = location
                streams[id] = stream
                return (Self.catchUpFetch, false, nil)
            }
            stream.anchor = location
            stream.frontier = location
            stream.nextChunk = firstChunk
            stream.window = window
            stream.stale = stream.pending.map(\.range)
            stream.pending = []
            streams[id] = stream
            return (seekFetch, false, nil)
        }
    }

    /// Asks the system to fetch the chunks after `fetched`, within the read-ahead window and the
    /// per-file and overall limits. Called as each fetch starts, so read-ahead runs alongside it.
    private func readAhead(id: String, after fetched: Range<Int64>, fileSize: Int64) {
        guard let manager else { return }
        let requests: [Range<Int64>] = lock.withLock {
            guard var stream = streams[id] else { return [] }
            stream.frontier = max(stream.frontier, fetched.upperBound)
            var inFlight = streams.values.reduce(0) { $0 + $1.pending.count }
            var requests: [Range<Int64>] = []
            while stream.pending.count < Self.readAheadPerFile, inFlight < Self.maximumReadAhead,
                  stream.frontier < fileSize, stream.frontier < stream.anchor + stream.window {
                let range = stream.frontier..<min(stream.frontier + stream.nextChunk, fileSize)
                stream.pending.append((range, Date()))
                stream.frontier = range.upperBound
                stream.nextChunk = min(stream.nextChunk * 2, Self.maximumChunk)
                requests.append(range)
                inFlight += 1
            }
            streams[id] = stream
            return requests
        }
        for range in requests {
            let nsRange = NSRange(location: Int(range.lowerBound), length: Int(range.upperBound - range.lowerBound))
            manager.requestDownloadForItem(withIdentifier: NSFileProviderItemIdentifier(id), requestedRange: nsRange) { [weak self] error in
                guard error != nil, let self else { return }
                self.lock.withLock { self.streams[id]?.pending.removeAll { $0.range == range } }
            }
        }
    }

    /// The aligned byte range to download for a read of `minimalRange`, at least `chunk` long.
    /// Small files, and reads covering most of a file, fetch the whole file.
    static func fetchRange(covering minimalRange: NSRange, alignment: Int, fileSize size: Int64,
                           chunk minimumChunk: Int64 = 8 * 1024 * 1024) -> Range<Int64> {
        let align = Int64(max(alignment, 1))
        let start = (Int64(minimalRange.location) / align) * align
        var end = max(Int64(minimalRange.location + minimalRange.length), start + minimumChunk)
        end = min(((end + align - 1) / align) * align, size)
        if size <= 16 * 1024 * 1024 || end - start >= size * 9 / 10 || start >= end {
            return 0..<max(size, 0)
        }
        return start..<end
    }

    /// Records a newer ETag/size reported by R2 for an item.
    private func applyServerInfo(_ info: R2Client.ObjectInfo, to record: ItemRecord, database: ItemDatabase) -> ItemRecord {
        guard (!info.etag.isEmpty && info.etag != record.etag) || info.size != record.size else { return record }
        var updated = database.record(id: record.id) ?? record
        updated.etag = info.etag.isEmpty ? updated.etag : info.etag
        updated.size = info.size
        updated.modified = info.lastModified ?? updated.modified
        let stored = database.update(updated)
        signalWorkingSet()
        return stored
    }

    /// Where returned content must live: the domain's temporary directory, on the same volume
    /// as the user-visible files.
    private func providerTemporaryDirectory() throws -> URL {
        if let manager, let url = try? manager.temporaryDirectoryURL() {
            return url
        }
        return FileManager.default.temporaryDirectory
    }

    private func makeProviderTemporaryFile() throws -> URL {
        let url = try providerTemporaryDirectory().appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }

    // MARK: - Create

    func createItem(
        template: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents: URL?,
        options: NSFileProviderCreateItemOptions,
        progress: Progress
    ) async throws -> FileProviderItem? {
        let name = template.filename
        let contentType = template.contentType ?? .data
        if Self.isExcluded(name) || contentType.conforms(to: .symbolicLink) {
            throw NSFileProviderError(.excludedFromSync)
        }

        let (client, database) = try context()
        let parentID = template.parentItemIdentifier.rawValue
        // Packages (.app, .key, ...) are directories too and are stored as folders.
        let isFolder = contentType.conforms(to: .directory)
        let mayAlreadyExist = options.contains(.mayAlreadyExist)
        let localDate: Date? = fields.contains(.contentModificationDate) ? (template.contentModificationDate ?? nil) : nil

        for _ in 0..<3 {
            guard let snapshot = database.record(id: parentID), snapshot.isFolder else {
                throw NSFileProviderError(.noSuchItem)
            }
            if snapshot.id == ItemDatabase.rootID && name + "/" == FinderDrive.trashPrefix {
                throw NSFileProviderError(.excludedFromSync)
            }
            let key = snapshot.key + name + (isFolder ? "/" : "")

            let outcome: FileProviderItem?? = try await withKeys([key]) {
                // The parent may have moved while we waited; start over with its new key.
                guard let parent = database.record(id: parentID), ItemDatabase.sameBytes(parent.key, snapshot.key) else {
                    return .none
                }

                if let existing = database.record(key: key) {
                    if isFolder && existing.isFolder { return .some(FileProviderItem(existing)) }
                    if mayAlreadyExist, try Self.contentMatches(contents, etag: existing.etag, size: existing.size) {
                        return .some(FileProviderItem(existing))
                    }
                    throw NSError.fileProviderErrorForCollision(with: FileProviderItem(existing))
                }

                if isFolder {
                    // A folder that already exists remotely is adopted; the system merges the two.
                    if try await client.prefixExists(key) {
                        let record = database.upsert(key: key, parentID: parent.id, name: name, isFolder: true,
                                                     size: 0, etag: "", modified: localDate)
                        return .some(FileProviderItem(record))
                    }
                    let info = try await client.putFolderMarker(key: key)
                    let record = database.upsert(key: key, parentID: parent.id, name: name, isFolder: true,
                                                 size: 0, etag: "", modified: localDate ?? info.lastModified)
                    return .some(FileProviderItem(record))
                }

                if let remote = try await client.head(key: key) {
                    let record = database.upsert(key: key, parentID: parent.id, name: name, isFolder: false,
                                                 size: remote.size, etag: remote.etag, modified: remote.lastModified)
                    signalWorkingSet()
                    if mayAlreadyExist, try Self.contentMatches(contents, etag: remote.etag, size: remote.size) {
                        return .some(FileProviderItem(record))
                    }
                    throw NSError.fileProviderErrorForCollision(with: FileProviderItem(record))
                }
                if mayAlreadyExist && contents == nil {
                    return .some(nil)
                }

                let info = try await upload(contents, key: key, name: name, client: client, database: database, progress: progress)
                let record = database.upsert(key: key, parentID: parent.id, name: name, isFolder: false,
                                             size: info.size, etag: info.etag, modified: localDate ?? info.lastModified)
                return .some(FileProviderItem(record))
            }
            if case .some(let item) = outcome {
                return item
            }
        }
        throw NSFileProviderError(.serverUnreachable)
    }

    /// Uploads new contents for `key`. Large files go up in parts recorded in the database, so an
    /// upload cut off by a network drop resumes when the system retries it.
    private func upload(_ contents: URL?, key: String, name: String, client: R2Client, database: ItemDatabase,
                        progress: Progress) async throws -> R2Client.ObjectInfo {
        let source: URL
        var temporary: URL?
        if let contents {
            source = contents
        } else {
            let empty = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            FileManager.default.createFile(atPath: empty.path, contents: Data())
            source = empty
            temporary = empty
        }
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }

        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }

        progress.totalUnitCount = max(Self.fileSize(source), 1)
        let mime = UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return try await client.upload(fileURL: source, key: key, contentType: mime, progress: progress, journal: database)
    }

    // MARK: - Modify

    /// Applies a rename, move, Trash move, or content edit. Returns the resulting item and
    /// whether the system should download the item's content again (after an edit conflict).
    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents: URL?,
        progress: Progress
    ) async throws -> (FileProviderItem?, Bool) {
        let (client, database) = try context()
        let id = item.itemIdentifier.rawValue

        for _ in 0..<3 {
            guard let snapshot = database.record(id: id) else { throw NSFileProviderError(.noSuchItem) }
            if snapshot.id == ItemDatabase.rootID || snapshot.id == ItemDatabase.trashID {
                return (FileProviderItem(snapshot), false)
            }

            let parentID = changedFields.contains(.parentItemIdentifier) ? item.parentItemIdentifier.rawValue : snapshot.parentID
            let name = changedFields.contains(.filename) ? item.filename : snapshot.name
            guard let parent = database.record(id: parentID), parent.isFolder else {
                throw NSFileProviderError(.noSuchItem)
            }
            let suffix = snapshot.isFolder ? "/" : ""
            let toTrash = parentID == ItemDatabase.trashID && snapshot.parentID != ItemDatabase.trashID
            let targetKey = parent.key + name + suffix
            let moving = !ItemDatabase.sameBytes(targetKey, snapshot.key)
            // Trash names are only chosen once the Trash is locked, so lock all of it.
            let keys = !moving ? [snapshot.key] : [snapshot.key, toTrash ? FinderDrive.trashPrefix : targetKey]

            let outcome: (FileProviderItem?, Bool)? = try await withKeys(keys) {
                guard var record = database.record(id: id), ItemDatabase.sameBytes(record.key, snapshot.key),
                      database.record(id: parentID).map({ ItemDatabase.sameBytes($0.key, parent.key) }) ?? false else {
                    return nil   // moved while we waited; plan again
                }

                if moving {
                    var newName = name
                    var newKey = targetKey
                    if toTrash {
                        newName = try await uniqueName(for: name, in: FinderDrive.trashPrefix, isFolder: record.isFolder,
                                                       client: client, database: database)
                        newKey = FinderDrive.trashPrefix + newName + suffix
                    } else if let occupant = try await occupant(of: newKey, isFolder: record.isFolder, excluding: id,
                                                                client: client, database: database) {
                        throw NSError.fileProviderErrorForCollision(with: FileProviderItem(occupant))
                    }
                    record = try await move(record, to: newKey, parentID: parentID, name: newName,
                                            client: client, database: database, progress: progress)
                }

                let localDate: Date? = changedFields.contains(.contentModificationDate) ? (item.contentModificationDate ?? nil) : nil
                if changedFields.contains(.contents), !record.isFolder, let contents {
                    if let conflict = try await resolveEditConflict(record, baseVersion: baseVersion, contents: contents,
                                                                    client: client, database: database, progress: progress) {
                        return (FileProviderItem(conflict), true)
                    }
                    let info = try await upload(contents, key: record.key, name: record.name, client: client, database: database,
                                               progress: progress)
                    record.size = info.size
                    record.etag = info.etag
                    record.modified = localDate ?? info.lastModified
                    record = database.update(record)
                } else if let localDate, localDate != record.modified {
                    record.modified = localDate
                    record = database.update(record)
                }
                return (FileProviderItem(record), false)
            }
            if let outcome {
                return outcome
            }
        }
        throw NSFileProviderError(.serverUnreachable)
    }

    /// If the file changed on R2 since the version the edit was based on, keeps both: the local
    /// edit is uploaded as a "conflicted copy" next to it, and the remote version stays put.
    /// Returns the item's updated record in that case, or nil when there is no conflict.
    private func resolveEditConflict(_ record: ItemRecord, baseVersion: NSFileProviderItemVersion, contents: URL,
                                     client: R2Client, database: ItemDatabase, progress: Progress) async throws -> ItemRecord? {
        guard baseVersion.contentVersion != NSFileProviderItemVersion.beforeFirstSyncComponent,
              let baseETag = String(data: baseVersion.contentVersion, encoding: .utf8), !baseETag.isEmpty,
              let remote = try await client.head(key: record.key), remote.etag != baseETag else {
            return nil
        }

        let parentKey = Self.parentKey(of: record.key) ?? ""
        let host = Host.current().localizedName ?? "this Mac"
        let copyName = try await uniqueName(for: record.name, in: parentKey, isFolder: false,
                                            suffix: "(conflicted copy from \(host))", client: client, database: database)
        let copyKey = parentKey + copyName
        let info = try await upload(contents, key: copyKey, name: copyName, client: client, database: database, progress: progress)
        database.upsert(key: copyKey, parentID: record.parentID, name: copyName, isFolder: false,
                        size: info.size, etag: info.etag, modified: info.lastModified)
        logger.info("Edit conflict: local changes saved as a conflicted copy")

        let updated = applyServerInfo(remote, to: record, database: database)
        signalWorkingSet()
        return updated
    }

    /// The item already at `key`, if any (checking R2 as well as the database).
    private func occupant(of key: String, isFolder: Bool, excluding id: String,
                          client: R2Client, database: ItemDatabase) async throws -> ItemRecord? {
        if let existing = database.record(key: key) {
            return ItemDatabase.sameBytes(existing.id, id) ? nil : existing
        }
        guard let parentKey = Self.parentKey(of: key), let parent = database.record(key: parentKey),
              let name = Self.childName(of: key, under: parentKey) else { return nil }
        if isFolder {
            guard try await client.prefixExists(key) else { return nil }
            return database.upsert(key: key, parentID: parent.id, name: name, isFolder: true, size: 0, etag: "", modified: nil)
        }
        guard let info = try await client.head(key: key) else { return nil }
        return database.upsert(key: key, parentID: parent.id, name: name, isFolder: false,
                               size: info.size, etag: info.etag, modified: info.lastModified)
    }

    /// Moves an object (or every object under a folder) to a new key: copy everything, then
    /// delete the originals. A failed copy is rolled back so a retry starts clean; a failed
    /// delete leaves stray originals behind but loses nothing.
    private func move(_ record: ItemRecord, to newKey: String, parentID: String, name: String,
                      client: R2Client, database: ItemDatabase, progress: Progress) async throws -> ItemRecord {
        let oldKey = record.key
        if record.isFolder {
            let objects = try await client.list(prefix: oldKey, delimiter: nil).objects
            progress.totalUnitCount = Int64(max(objects.count * 2, 1))
            let copied = LockedList<String>()
            do {
                if objects.isEmpty {
                    _ = try await client.putFolderMarker(key: newKey)
                    copied.append(newKey)
                }
                try await Self.forEach(objects, concurrency: 4) { object in
                    let relative = String(String.UnicodeScalarView(object.key.unicodeScalars.dropFirst(oldKey.unicodeScalars.count)))
                    try await client.copy(from: object.key, to: newKey + relative, size: object.size)
                    copied.append(newKey + relative)
                    progress.completedUnitCount += 1
                }
            } catch {
                try? await Self.forEach(copied.values, concurrency: 8) { try await client.delete(key: $0) }
                throw error
            }
            do {
                try await Self.forEach(objects, concurrency: 8) { object in
                    try await client.delete(key: object.key)
                    progress.completedUnitCount += 1
                }
            } catch {
                logger.error("Some originals were left behind after a folder move: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            try await client.copy(from: oldKey, to: newKey, size: record.size)
            do {
                try await client.delete(key: oldKey)
            } catch {
                logger.error("Original left behind after a move: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard let moved = database.move(id: record.id, toKey: newKey, parentID: parentID, name: name) else {
            throw NSFileProviderError(.noSuchItem)
        }
        return moved
    }

    // MARK: - Delete

    func deleteItem(id: String, baseVersion: NSFileProviderItemVersion, recursive: Bool, progress: Progress) async throws {
        if id == ItemDatabase.rootID || id == ItemDatabase.trashID {
            throw NSFileProviderError(.deletionRejected)
        }
        let (client, database) = try context()

        for _ in 0..<3 {
            guard let snapshot = database.record(id: id) else { return }
            let done: Bool = try await withKeys([snapshot.key]) {
                guard let record = database.record(id: id) else { return true }
                guard ItemDatabase.sameBytes(record.key, snapshot.key) else { return false }

                if record.isFolder {
                    let objects = try await client.list(prefix: record.key, delimiter: nil).objects
                    if !recursive && objects.contains(where: { !ItemDatabase.sameBytes($0.key, record.key) }) {
                        throw NSFileProviderError(.directoryNotEmpty)
                    }
                    progress.totalUnitCount = Int64(max(objects.count, 1))
                    try await Self.forEach(objects, concurrency: 8) { object in
                        try await client.delete(key: object.key)
                        progress.completedUnitCount += 1
                    }
                } else {
                    // Don't delete a version of the file the user never saw.
                    if baseVersion.contentVersion != NSFileProviderItemVersion.beforeFirstSyncComponent,
                       let baseETag = String(data: baseVersion.contentVersion, encoding: .utf8), !baseETag.isEmpty,
                       let remote = try await client.head(key: record.key), remote.etag != baseETag {
                        _ = applyServerInfo(remote, to: record, database: database)
                        throw NSFileProviderError(.deletionRejected)
                    }
                    try await client.delete(key: record.key)
                }
                database.remove(id: record.id)
                if record.isFolder {
                    // Descendants were tombstoned; let the working set report them.
                    signalWorkingSet()
                }
                return true
            }
            if done { return }
        }
        throw NSFileProviderError(.serverUnreachable)
    }

    // MARK: - Helpers

    /// Finder metadata that should stay local.
    static func isExcluded(_ name: String) -> Bool {
        name == ".DS_Store" || name.hasPrefix("._") || name == ".localized"
            || name == ".TemporaryItems" || name == ".Trashes" || name == ".fseventsd"
    }

    /// The single path component of `key` directly under `parentKey`, or nil if `key` isn't a direct child.
    static func childName(of key: String, under parentKey: String) -> String? {
        guard key.utf8.starts(with: parentKey.utf8) else { return nil }
        var relative = String(String.UnicodeScalarView(key.unicodeScalars.dropFirst(parentKey.unicodeScalars.count)))
        if relative.hasSuffix("/") { relative.removeLast() }
        guard !relative.isEmpty, relative != ".", relative != "..", !relative.contains("/"),
              relative.utf8.count <= 255 else { return nil }
        return relative
    }

    /// "a/b/c" -> "a/b/", "a/b/" -> "a/", "a" -> "".
    static func parentKey(of key: String) -> String? {
        var trimmed = key
        if trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return nil }
        guard let slash = trimmed.lastIndex(of: "/") else { return "" }
        return String(trimmed[...slash])
    }

    static func fileSize(_ url: URL?) -> Int64 {
        guard let url, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return 0 }
        return Int64(size)
    }

    /// Whether a local file is the same as the R2 object with `etag`. Single-part ETags are the
    /// MD5 of the content; multipart ETags are checked against the part size this app uploads with.
    /// A dataless file (no contents) is taken to match.
    static func contentMatches(_ contents: URL?, etag: String, size: Int64) throws -> Bool {
        guard let contents else { return true }
        guard fileSize(contents) == size, !etag.isEmpty else { return false }

        let accessing = contents.startAccessingSecurityScopedResource()
        defer { if accessing { contents.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: contents)
        defer { try? handle.close() }

        func md5(length: Int64) throws -> Data {
            var hasher = Insecure.MD5()
            var remaining = length
            while remaining > 0, let chunk = try handle.read(upToCount: Int(min(remaining, 4 * 1024 * 1024))), !chunk.isEmpty {
                hasher.update(data: chunk)
                remaining -= Int64(chunk.count)
            }
            return Data(hasher.finalize())
        }
        func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

        if let dash = etag.lastIndex(of: "-"), let parts = Int(etag[etag.index(after: dash)...]) {
            let partSize = R2Client.multipartPartSize(for: size)
            guard (size + partSize - 1) / partSize == Int64(parts) else { return false }
            var digests = Data()
            for part in 0..<parts {
                digests.append(try md5(length: min(partSize, size - Int64(part) * partSize)))
            }
            return hex(Data(Insecure.MD5.hash(data: digests))) + "-\(parts)" == etag
        }
        return hex(try md5(length: size)) == etag
    }

    static func elapsed(since start: Date) -> String {
        String(format: "%.2fs", Date().timeIntervalSince(start))
    }

    /// "8.0 MB in 1.20s (6.7 MB/s)" for logs.
    static func throughput(_ bytes: Int64, since start: Date) -> String {
        let seconds = max(Date().timeIntervalSince(start), 0.001)
        let megabytes = Double(bytes) / 1_048_576
        return String(format: "%.1f MB in %.2fs (%.1f MB/s)", megabytes, seconds, megabytes / seconds)
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return (error as? CocoaError)?.code == .userCancelled
    }

    /// Runs `body` over `items` with at most `concurrency` calls in flight.
    static func forEach<T: Sendable>(_ items: [T], concurrency: Int,
                                     _ body: @escaping @Sendable (T) async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = items.makeIterator()
            for _ in 0..<concurrency {
                guard let item = iterator.next() else { break }
                group.addTask { try await body(item) }
            }
            while try await group.next() != nil {
                if let item = iterator.next() {
                    group.addTask { try await body(item) }
                }
            }
        }
    }

    /// Maps errors to the domains the File Provider framework accepts.
    static func fileProviderError(_ error: Error) -> Error {
        if error is CancellationError { return CocoaError(.userCancelled) }
        let nsError = error as NSError
        if nsError.domain == NSFileProviderErrorDomain || nsError.domain == NSCocoaErrorDomain {
            return error
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return CocoaError(.userCancelled)
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
                 .cannotConnectToHost, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed,
                 .secureConnectionFailed:
                return NSFileProviderError(.serverUnreachable)
            default:
                break
            }
        }
        if case R2Client.ClientError.http(let status, let code, _) = error {
            switch (status, code) {
            case (401, _), (403, _), (_, "NoSuchBucket"), (_, "InvalidAccessKeyId"), (_, "SignatureDoesNotMatch"):
                return NSFileProviderError(.notAuthenticated)
            case (404, _):
                return NSFileProviderError(.noSuchItem)
            case (412, _):
                return NSFileProviderError(.versionNoLongerAvailable)
            case (500..., _):
                return NSFileProviderError(.serverUnreachable)
            default:
                break
            }
        }
        return NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionReplyInvalid,
                       userInfo: [NSUnderlyingErrorKey: error, NSLocalizedDescriptionKey: error.localizedDescription])
    }
}

/// A list that concurrent tasks can append to.
private final class LockedList<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Element] = []

    func append(_ item: Element) {
        lock.withLock { items.append(item) }
    }

    var values: [Element] {
        lock.withLock { items }
    }
}
