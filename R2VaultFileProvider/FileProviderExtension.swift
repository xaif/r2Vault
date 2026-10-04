import FileProvider

/// Principal class of the R2 Vault Finder drive. Each domain is one R2 bucket.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension,
                                   NSFileProviderPartialContentFetching, NSFileProviderServicing, NSFileProviderCustomAction {
    /// Finder actions declared under NSExtensionFileProviderActions in Info.plist.
    static let keepDownloadedAction = "fiaxe.Fiaxe.FileProvider.keepDownloaded"
    static let stopKeepingDownloadedAction = "fiaxe.Fiaxe.FileProvider.stopKeepingDownloaded"

    private let drive: R2Drive

    required init(domain: NSFileProviderDomain) {
        drive = R2Drive(domain: domain)
        super.init()
    }

    func invalidate() {
        drive.invalidate()
    }

    // MARK: - Items

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        do {
            completionHandler(try drive.item(for: identifier.rawValue), nil)
        } catch {
            completionHandler(nil, R2Drive.fileProviderError(error))
        }
        return Progress()
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        perform(progress, {
            try await self.drive.fetchContents(id: itemIdentifier.rawValue, progress: progress)
        }, completion: { result in
            switch result {
            case .success(let (url, item)): completionHandler(url, item, nil)
            case .failure(let error): completionHandler(nil, nil, error)
            }
        })
        return progress
    }

    func fetchPartialContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion,
                              request: NSFileProviderRequest, minimalRange requestedRange: NSRange, aligningTo alignment: Int,
                              options: NSFileProviderFetchContentsOptions,
                              completionHandler: @escaping (URL?, NSFileProviderItem?, NSRange, NSFileProviderMaterializationFlags, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        perform(progress, {
            try await self.drive.fetchPartialContents(
                id: itemIdentifier.rawValue,
                version: requestedVersion,
                minimalRange: requestedRange,
                alignment: alignment,
                strictVersioning: options.contains(.strictVersioning),
                progress: progress
            )
        }, completion: { result in
            switch result {
            case .success(let (url, item, range)): completionHandler(url, item, range, [], nil)
            case .failure(let error): completionHandler(nil, nil, NSRange(location: 0, length: 0), [], error)
            }
        })
        return progress
    }

    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        perform(progress, {
            try await self.drive.createItem(template: itemTemplate, fields: fields, contents: url,
                                            options: options, progress: progress)
        }, completion: { result in
            switch result {
            case .success(let item): completionHandler(item, [], false, nil)
            case .failure(let error): completionHandler(nil, [], false, error)
            }
        })
        return progress
    }

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields, contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        perform(progress, {
            try await self.drive.modifyItem(item, baseVersion: version, changedFields: changedFields,
                                            contents: newContents, progress: progress)
        }, completion: { result in
            switch result {
            case .success(let (item, shouldFetchContent)): completionHandler(item, [], shouldFetchContent, nil)
            case .failure(let error): completionHandler(nil, [], false, error)
            }
        })
        return progress
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        perform(progress, {
            try await self.drive.deleteItem(id: identifier.rawValue, baseVersion: version,
                                            recursive: options.contains(.recursive), progress: progress)
        }, completion: { result in
            switch result {
            case .success: completionHandler(nil)
            case .failure(let error): completionHandler(error)
            }
        })
        return progress
    }

    // MARK: - Enumeration

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        switch containerItemIdentifier {
        case .workingSet:
            return WorkingSetEnumerator(drive: drive)
        case .rootContainer, .trashContainer:
            return FolderEnumerator(folderID: containerItemIdentifier.rawValue, drive: drive)
        default:
            let (_, database) = try drive.context()
            guard let record = database.record(id: containerItemIdentifier.rawValue) else {
                throw NSFileProviderError(.noSuchItem)
            }
            guard record.isFolder else {
                // Single-document enumerators only need to exist; updates arrive through the working set.
                return FolderEnumerator(folderID: record.id, drive: drive, isDocument: true)
            }
            return FolderEnumerator(folderID: record.id, drive: drive)
        }
    }

    // MARK: - Services

    func supportedServiceSources(for itemIdentifier: NSFileProviderItemIdentifier,
                                 completionHandler: @escaping ([NSFileProviderServiceSource]?, Error?) -> Void) -> Progress {
        completionHandler([drive.controlService], nil)
        return Progress()
    }

    // MARK: - Finder actions

    func performAction(identifier actionIdentifier: NSFileProviderExtensionActionIdentifier,
                       onItemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier],
                       completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let ids = itemIdentifiers.map(\.rawValue)
        perform(progress, {
            switch actionIdentifier.rawValue {
            case Self.keepDownloadedAction: try self.drive.setKeepDownloaded(true, ids: ids)
            case Self.stopKeepingDownloadedAction: try self.drive.setKeepDownloaded(false, ids: ids)
            default: throw CocoaError(.featureUnsupported)
            }
        }, completion: { result in
            switch result {
            case .success: completionHandler(nil)
            case .failure(let error): completionHandler(error)
            }
        })
        return progress
    }

    // MARK: - Helpers

    /// Runs `operation`, maps its error, and cancels it when the system cancels `progress`.
    private func perform<T>(_ progress: Progress, _ operation: @escaping @Sendable () async throws -> T,
                            completion: @escaping @Sendable (Result<T, Error>) -> Void) {
        let task = Task {
            do {
                completion(.success(try await operation()))
            } catch {
                completion(.failure(R2Drive.fileProviderError(error)))
            }
        }
        progress.cancellationHandler = { task.cancel() }
    }
}

// MARK: - Enumerators

/// Lists one folder (or the Trash) straight from R2.
final class FolderEnumerator: NSObject, NSFileProviderEnumerator {
    private let folderID: String
    private let drive: R2Drive
    private let isDocument: Bool

    init(folderID: String, drive: R2Drive, isDocument: Bool = false) {
        self.folderID = folderID
        self.drive = drive
        self.isDocument = isDocument
        super.init()
        if !isDocument { drive.folderOpened(folderID) }
    }

    func invalidate() {
        if !isDocument { drive.folderClosed(folderID) }
    }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        if isDocument {
            observer.finishEnumerating(upTo: nil)
            return
        }
        let drive = drive
        let folderID = folderID
        Task {
            do {
                let records = try await drive.listFolder(id: folderID)
                for start in stride(from: 0, to: records.count, by: 500) {
                    let batch = records[start..<min(start + 500, records.count)]
                    observer.didEnumerate(batch.map(FileProviderItem.init))
                }
                observer.finishEnumerating(upTo: nil)
            } catch {
                observer.finishEnumeratingWithError(R2Drive.fileProviderError(error))
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from syncAnchor: NSFileProviderSyncAnchor) {
        // Replicated domains receive remote changes through the working set.
        observer.finishEnumeratingChanges(upTo: syncAnchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        guard let (_, database) = try? drive.context() else {
            completionHandler(nil)
            return
        }
        completionHandler(drive.syncAnchor(for: database.currentSeq, database: database))
    }
}

/// Reports every change the extension has recorded, keyed by the database's change counter.
final class WorkingSetEnumerator: NSObject, NSFileProviderEnumerator {
    private let drive: R2Drive

    init(drive: R2Drive) {
        self.drive = drive
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let database: ItemDatabase
        do {
            database = try drive.context().database
        } catch {
            observer.finishEnumeratingWithError(R2Drive.fileProviderError(error))
            return
        }
        // Our own pages are "rowid:<n>"; the system's initial pages decode to nothing.
        let text = String(data: page.rawValue, encoding: .utf8) ?? ""
        let after = text.hasPrefix("rowid:") ? Int64(text.dropFirst(6)) ?? 0 : 0

        let limit = 1000
        let (records, lastRowID) = database.allItems(after: after, limit: limit)
        observer.didEnumerate(records.map(FileProviderItem.init))
        if records.count == limit {
            observer.finishEnumerating(upTo: NSFileProviderPage(Data("rowid:\(lastRowID)".utf8)))
        } else {
            observer.finishEnumerating(upTo: nil)
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from syncAnchor: NSFileProviderSyncAnchor) {
        let drive = drive
        Task {
            let database: ItemDatabase
            do {
                database = try drive.context().database
            } catch {
                observer.finishEnumeratingWithError(R2Drive.fileProviderError(error))
                return
            }
            guard let since = drive.seq(from: syncAnchor, database: database) else {
                observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
                return
            }

            await drive.refreshStaleFolders()

            let changes = database.changes(since: since)
            if !changes.deleted.isEmpty {
                observer.didDeleteItems(withIdentifiers: changes.deleted.map { NSFileProviderItemIdentifier($0) })
            }
            for start in stride(from: 0, to: changes.updated.count, by: 500) {
                let batch = changes.updated[start..<min(start + 500, changes.updated.count)]
                observer.didUpdate(batch.map(FileProviderItem.init))
            }
            observer.finishEnumeratingChanges(upTo: drive.syncAnchor(for: changes.latest, database: database),
                                              moreComing: false)
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        guard let (_, database) = try? drive.context() else {
            completionHandler(nil)
            return
        }
        completionHandler(drive.syncAnchor(for: database.currentSeq, database: database))
    }
}

// MARK: - Control service

/// XPC endpoint the app uses to hand the extension its bucket credentials.
/// Restricted, so only the app that manages the domain can connect.
final class DriveControlService: NSObject, NSFileProviderServiceSource, NSXPCListenerDelegate, FinderDriveControlProtocol {
    let serviceName = FinderDrive.controlServiceName
    weak var drive: R2Drive?
    private let listener = NSXPCListener.anonymous()

    override init() {
        super.init()
        listener.delegate = self
        listener.resume()
    }

    var isRestricted: Bool { true }

    func makeListenerEndpoint() throws -> NSXPCListenerEndpoint {
        listener.endpoint
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: FinderDriveControlProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }

    func updateCredentials(_ payload: Data, reply: @escaping (NSError?) -> Void) {
        do {
            let credentials = try JSONDecoder().decode(R2Credentials.self, from: payload)
            try drive?.setCredentials(credentials)
            reply(nil)
        } catch {
            reply(error as NSError)
        }
    }

    func refresh(reply: @escaping (NSError?) -> Void) {
        guard let drive else {
            reply(nil)
            return
        }
        Task {
            await drive.refreshStaleFolders(force: true, openOnly: true)
            drive.signalWorkingSet()
            reply(nil)
        }
    }
}
