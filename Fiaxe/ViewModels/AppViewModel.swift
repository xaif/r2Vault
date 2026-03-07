import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import UniformTypeIdentifiers

// MARK: - Browser View Mode / Sort / Filter

enum BrowserViewMode: String, CaseIterable, Identifiable {
    case icons = "Icons"
    case list  = "List"
    var id: String { rawValue }
}

enum BrowserSortKey: String, CaseIterable, Identifiable {
    case name       = "Name"
    case size       = "Size"
    case date       = "Date Modified"
    case kind       = "Kind"
    var id: String { rawValue }
}

@Observable
final class AppViewModel {
    // Upload queue
    var uploadTasks: [FileUploadTask] = []

    // History
    let historyStore = UploadHistoryStore()

    // Credentials
    var credentialsList: [R2Credentials] = []
    var selectedCredentialID: UUID?

    var credentials: R2Credentials? {
        guard let selectedCredentialID else { return credentialsList.first }
        return credentialsList.first { $0.id == selectedCredentialID } ?? credentialsList.first
    }

    var hasCredentials: Bool { !(credentials?.isEmpty ?? true) }

    // UI state
    var showFileImporter = false
    var showFolderImporter = false
#if os(iOS)
    var showPhotoPicker = false
#endif
    var alertMessage: String?
    var showAlert = false

    /// Set briefly after a successful upload to trigger "Link copied!" toast
    var clipboardToastFileName: String? = nil

#if os(macOS)
    /// Registered by the SwiftUI scene to reopen the main window when it has been closed.
    var openMainWindow: (() -> Void)? = nil
#endif

    // Update state
    enum UpdateStatus {
        case idle
        case checking
        case upToDate
        case available(GitHubRelease)
        case failed(String)

        var isChecking: Bool {
            if case .checking = self { return true }
            return false
        }
    }
    var updateStatus: UpdateStatus = .idle
    var showUpdateSheet = false

    // MARK: - Dashboard state

    var bucketStats: BucketStats?
    var isScanning = false
    var scanError: String?

    // MARK: - Browser state

    /// The current folder prefix (e.g. "photos/vacation/"). Empty string = root.
    var currentPrefix: String = ""
    /// Prefixes we can go back to
    var backStack: [String] = []
    /// Prefixes we can go forward to (cleared on any new navigation)
    var forwardStack: [String] = []
    /// Files in the current folder
    var browserObjects: [R2Object] = []
    /// Subfolders in the current folder
    var browserFolders: [R2Object] = []
    /// True while a ListObjects request is in flight
    var isBrowsing = false
    /// Non-nil when the last browse attempt failed
    var browserError: String?
    /// Monotonic request token so stale folder loads cannot overwrite newer navigation state.
    private var browserLoadGeneration: Int = 0
    /// The currently active browse task so newer navigation can cancel older folder loads.
    private var browserLoadTask: Task<Void, Never>?
    /// Per-bucket folder cache to avoid re-showing the loading state on revisits.
    private var browserFolderCache: [String: BrowserFolderCacheEntry] = [:]
    /// Recursive object cache used for in-folder search.
    private var browserSearchCache: [String: [R2Object]] = [:]
    /// Search results shown when the user searches within the current folder subtree.
    private var browserSearchResults: [R2Object] = []
    /// The folder prefix the current recursive search results belong to.
    private var browserSearchPrefix: String?
    /// The currently active recursive search task.
    private var browserSearchTask: Task<Void, Never>?
    /// True while a recursive subtree search is in flight.
    var isSearching = false

    /// Path segments derived from `currentPrefix`, e.g. ["photos", "vacation"]
    var pathSegments: [String] {
        currentPrefix
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
    }

    // View preferences
    var viewMode: BrowserViewMode = .list
    var sortKey: BrowserSortKey = .name
    var sortAscending: Bool = true
    var filterText: String = "" {
        didSet {
            guard filterText != oldValue else { return }
            refreshBrowserSearch()
        }
    }
    /// Selected object IDs for multi-select operations
    var selectedObjectIDs: Set<UUID> = []


    /// All items merged (folders first by default, then files), sorted and filtered
    var allBrowserItems: [R2Object] {
        let combined = browserFolders + browserObjects
        if filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return sortedBrowserItems(combined)
        }

        let visibleMatches = combined.filter { matchesSearchQuery($0, query: filterText) }
        let recursiveMatches = browserSearchPrefix == currentPrefix
            ? browserSearchResults.filter { candidate in
            !visibleMatches.contains(where: { $0.key == candidate.key && $0.isFolder == candidate.isFolder })
        }
            : []

        return sortedBrowserItems(visibleMatches + recursiveMatches)
    }

    private func sortedBrowserItems(_ items: [R2Object]) -> [R2Object] {
        items.sorted { a, b in
            // Folders always sort before files when sorting by name/date/kind
            if sortKey != .size && a.isFolder != b.isFolder {
                return a.isFolder
            }
            let result: Bool
            switch sortKey {
            case .name:
                result = a.name.localizedCompare(b.name) == .orderedAscending
            case .size:
                result = a.size < b.size
            case .date:
                let aDate = a.lastModified ?? .distantPast
                let bDate = b.lastModified ?? .distantPast
                result = aDate < bDate
            case .kind:
                result = a.isFolder == b.isFolder
                    ? a.name.localizedCompare(b.name) == .orderedAscending
                    : a.isFolder
            }
            return sortAscending ? result : !result
        }
    }

    init() {
        loadCredentials()
#if os(iOS)
        processShareInbox()
#endif
    }

    // MARK: - Credentials

    func loadCredentials() {
        do {
            credentialsList = try KeychainService.loadAll()
            if selectedCredentialID == nil {
                selectedCredentialID = credentialsList.first?.id
            }
        } catch {
            showError("Failed to load credentials: \(error.localizedDescription)")
        }
    }

    func saveCredentials(_ creds: R2Credentials) {
        let isNew = !credentialsList.contains(where: { $0.id == creds.id })
        if let idx = credentialsList.firstIndex(where: { $0.id == creds.id }) {
            credentialsList[idx] = creds
        } else {
            credentialsList.append(creds)
        }
        do {
            try KeychainService.saveAll(credentialsList)
        } catch {
            showError("Failed to save credentials: \(error.localizedDescription)")
        }
        if isNew {
            // New bucket: reset browser and load fresh
            selectedCredentialID = creds.id
            currentPrefix = ""
            backStack = []
            forwardStack = []
            browserObjects = []
            browserFolders = []
            browserError = nil
            selectedObjectIDs = []
            invalidateBrowserCache()
            Task { await ThumbnailCache.shared.clearMemory() }
            loadCurrentFolder()
        } else {
            selectedCredentialID = creds.id
        }
    }

    func deleteCredentials(id: UUID) {
        credentialsList.removeAll { $0.id == id }
        if selectedCredentialID == id {
            selectedCredentialID = credentialsList.first?.id
        }
        do {
            try KeychainService.saveAll(credentialsList)
        } catch {
            showError("Failed to save credentials: \(error.localizedDescription)")
        }
    }

    func selectCredentials(id: UUID) {
        guard id != selectedCredentialID else { return }
        selectedCredentialID = id
        currentPrefix = ""
        backStack = []
        forwardStack = []
        browserObjects = []
        browserFolders = []
        browserError = nil
        selectedObjectIDs = []
        invalidateBrowserCache()
        Task { await ThumbnailCache.shared.clearMemory() }
        loadCurrentFolder()
    }

    func testConnection() async -> Bool {
        guard let credentials else { return false }
        do {
            return try await R2UploadService.testConnection(credentials: credentials)
        } catch {
            showError("Connection test failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Browser Navigation

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    @MainActor
    func loadCurrentFolder() {
        guard let credentials else {
            browserError = "Please configure R2 credentials in Settings."
            return
        }
        let requestedPrefix = currentPrefix
        let cacheKey = browserCacheKey(credentialsID: credentials.id, prefix: requestedPrefix)
        let cachedEntry = browserFolderCache[cacheKey]
        browserLoadTask?.cancel()
        browserLoadGeneration += 1
        let requestGeneration = browserLoadGeneration
        if let cachedEntry {
            browserObjects = cachedEntry.objects
            browserFolders = cachedEntry.folders
            isBrowsing = false
            refreshBrowserSearch()
        } else {
            browserObjects = []
            browserFolders = []
            isBrowsing = true
        }
        browserError = nil
        browserLoadTask = Task {
            do {
                let result = try await R2BrowseService.listObjects(
                    credentials: credentials,
                    prefix: requestedPrefix
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard requestGeneration == self.browserLoadGeneration, requestedPrefix == self.currentPrefix else { return }
                    let objects = result.objects
                        .filter { !$0.key.hasSuffix("/") }   // skip zero-byte folder markers
                    let folders = result.folders
                    self.browserObjects = objects
                    self.browserFolders = folders
                    self.browserFolderCache[cacheKey] = BrowserFolderCacheEntry(objects: objects, folders: folders)
                    self.isBrowsing = false
                    self.refreshBrowserSearch()
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard requestGeneration == self.browserLoadGeneration, requestedPrefix == self.currentPrefix else { return }
                    if cachedEntry == nil {
                        self.browserError = error.localizedDescription
                    }
                    self.isBrowsing = false
                    self.refreshBrowserSearch()
                }
            }
        }
    }

    @MainActor
    func navigateToFolder(_ object: R2Object) {
        guard object.isFolder else { return }
        navigate(to: object.key, history: .pushCurrentClearForward)
    }

    /// Navigate to a path segment by index into `pathSegments`.
    @MainActor
    func navigateToSegment(_ index: Int) {
        let segments = pathSegments
        guard index < segments.count else { return }
        let newSegments = Array(segments.prefix(index + 1))
        let newPrefix = newSegments.joined(separator: "/") + "/"
        navigate(to: newPrefix, history: .pushCurrentClearForward)
    }

    @MainActor
    func navigateToRoot() {
        navigate(to: "", history: .pushCurrentClearForward)
    }

    @MainActor
    func navigateBack() {
        guard let previous = backStack.popLast() else { return }
        navigate(to: previous, history: .pushCurrentToForward)
    }

    @MainActor
    func navigateForward() {
        guard let next = forwardStack.popLast() else { return }
        navigate(to: next, history: .pushCurrentToBack)
    }

    @MainActor
    private func navigate(to newPrefix: String, history: BrowserHistoryMutation) {
        guard newPrefix != currentPrefix else { return }

        switch history {
        case .pushCurrentClearForward:
            backStack.append(currentPrefix)
            forwardStack.removeAll()
        case .pushCurrentToForward:
            forwardStack.append(currentPrefix)
        case .pushCurrentToBack:
            backStack.append(currentPrefix)
        }

        browserError = nil
        selectedObjectIDs = []
        currentPrefix = newPrefix
        loadCurrentFolder()
        refreshBrowserSearch()
    }

    private enum BrowserHistoryMutation {
        case pushCurrentClearForward
        case pushCurrentToForward
        case pushCurrentToBack
    }

    private struct BrowserFolderCacheEntry {
        let objects: [R2Object]
        let folders: [R2Object]
    }

    private func browserCacheKey(credentialsID: UUID, prefix: String) -> String {
        "\(credentialsID.uuidString)::\(prefix)"
    }

    private func matchesSearchQuery(_ object: R2Object, query: String) -> Bool {
        object.name.localizedCaseInsensitiveContains(query)
            || object.key.localizedCaseInsensitiveContains(query)
    }

    private func invalidateBrowserCache() {
        browserFolderCache.removeAll()
        browserSearchCache.removeAll()
        browserSearchResults = []
        browserSearchPrefix = nil
        browserSearchTask?.cancel()
        isSearching = false
    }

    private func refreshBrowserSearch() {
        browserSearchTask?.cancel()

        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            browserSearchResults = []
            browserSearchPrefix = nil
            isSearching = false
            return
        }

        guard let credentials else {
            browserSearchResults = []
            browserSearchPrefix = nil
            isSearching = false
            return
        }

        let searchPrefix = currentPrefix
        let directMatches = (browserFolders + browserObjects).filter { matchesSearchQuery($0, query: query) }
        let cacheKey = browserCacheKey(credentialsID: credentials.id, prefix: searchPrefix)

        browserSearchResults = directMatches
        browserSearchPrefix = searchPrefix

        if let cachedObjects = browserSearchCache[cacheKey] {
            guard searchPrefix == currentPrefix, query == filterText.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            browserSearchResults = cachedObjects.filter { matchesSearchQuery($0, query: query) }
            browserSearchPrefix = searchPrefix
            isSearching = false
            return
        }

        isSearching = true

        browserSearchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let subtreeObjects = try await Self.listAllObjectsWithDetails(
                    credentials: credentials,
                    prefix: searchPrefix
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.currentPrefix == searchPrefix else { return }
                    let currentQuery = self.filterText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard currentQuery == query else { return }
                    self.browserSearchCache[cacheKey] = subtreeObjects
                    self.browserSearchResults = subtreeObjects.filter {
                        self.matchesSearchQuery($0, query: currentQuery)
                    }
                    self.browserSearchPrefix = searchPrefix
                    self.isSearching = false
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.currentPrefix == searchPrefix else { return }
                    let currentQuery = self.filterText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard currentQuery == query else { return }
                    self.browserSearchPrefix = searchPrefix
                    self.isSearching = false
                }
            }
        }
    }

    func createFolder(name: String) async {
        guard let credentials else { return }
        let folderKey = currentPrefix + name + "/"
        do {
            try await R2BrowseService.createFolder(credentials: credentials, folderKey: folderKey)
            invalidateBrowserCache()
            loadCurrentFolder()
        } catch {
            showError("Failed to create folder: \(error.localizedDescription)")
        }
    }

    func deleteObject(_ object: R2Object) async {
        guard let credentials else { return }
        do {
            if object.isFolder {
                try await deleteRecursive(prefix: object.key, credentials: credentials)
            } else {
                try await R2BrowseService.deleteObject(credentials: credentials, key: object.key)
            }
            invalidateBrowserCache()
            loadCurrentFolder()
        } catch {
            showError("Failed to delete: \(error.localizedDescription)")
        }
    }

    func deleteSelected() async {
        guard let credentials else { return }
        let toDelete = allBrowserItems.filter { selectedObjectIDs.contains($0.id) }
        selectedObjectIDs.removeAll()
        await withTaskGroup(of: Void.self) { group in
            for object in toDelete {
                group.addTask {
                    do {
                        if object.isFolder {
                            try await self.deleteRecursive(prefix: object.key, credentials: credentials)
                        } else {
                            try? await R2BrowseService.deleteObject(credentials: credentials, key: object.key)
                        }
                    } catch {
                        // Individual folder delete errors are silently ignored to not block other deletions
                    }
                }
            }
        }
        invalidateBrowserCache()
        loadCurrentFolder()
    }

    /// Recursively deletes all objects under `prefix` (including the folder placeholder itself).
    private func deleteRecursive(prefix: String, credentials: R2Credentials) async throws {
        let keys = try await R2BrowseService.listAllKeys(credentials: credentials, prefix: prefix)
        // Delete all found keys concurrently
        try await withThrowingTaskGroup(of: Void.self) { group in
            for key in keys {
                group.addTask {
                    try await R2BrowseService.deleteObject(credentials: credentials, key: key)
                }
            }
            try await group.waitForAll()
        }
    }

    func selectAll() {
        selectedObjectIDs = Set(allBrowserItems.map(\.id))
    }

    func clearSelection() {
        selectedObjectIDs.removeAll()
    }

    // MARK: - Drag-and-Drop / File Handling

    /// Handles URLs dropped from Finder (macOS) or picked via document picker (iOS).
    /// Directories are recursively enumerated on macOS; on iOS only flat files are expected.
    @MainActor
    func handleDroppedURLs(_ urls: [URL]) {
        var tasks: [FileUploadTask] = []

        for url in urls {
#if os(macOS)
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            guard exists else { continue }

            if isDirectory.boolValue {
                // Recursively enumerate directory contents
                let folderBookmark = try? url.bookmarkData(options: [.withSecurityScope],
                                                         includingResourceValuesForKeys: nil,
                                                         relativeTo: nil)
                guard let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for case let fileURL as URL in enumerator {
                    let fileAccessing = fileURL.startAccessingSecurityScopedResource()
                    defer { if fileAccessing { fileURL.stopAccessingSecurityScopedResource() } }

                    let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                    guard values?.isDirectory == false else { continue }

                    // Preserve relative path: dirName/relative/path/to/file
                    let relativePath = fileURL.path.replacingOccurrences(
                        of: url.deletingLastPathComponent().path + "/",
                        with: ""
                    )
                    let r2Key = currentPrefix + relativePath
                    let fileName = fileURL.lastPathComponent
                    let fileSize = Int64(values?.fileSize ?? 0)

                    let task = FileUploadTask(fileURL: fileURL, fileName: fileName, fileSize: fileSize)
                    configureUploadTask(task)
                    task.uploadKey = r2Key
                    task.parentFolderBookmark = folderBookmark
                    tasks.append(task)
                }
            } else {
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .nameKey])
                let fileName = values?.name ?? url.lastPathComponent
                let fileSize = Int64(values?.fileSize ?? 0)
                let r2Key = currentPrefix + fileName

                let task = FileUploadTask(fileURL: url, fileName: fileName, fileSize: fileSize)
                configureUploadTask(task)
                task.uploadKey = r2Key
                tasks.append(task)
            }
#else
            // iOS: treat each URL as a flat file
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .nameKey])
            let fileName = values?.name ?? url.lastPathComponent
            let fileSize = Int64(values?.fileSize ?? 0)
            let r2Key = currentPrefix + fileName

            let task = FileUploadTask(fileURL: url, fileName: fileName, fileSize: fileSize)
            configureUploadTask(task)
            task.uploadKey = r2Key
            tasks.append(task)
#endif
        }

        guard !tasks.isEmpty else { return }
        uploadTasks.append(contentsOf: tasks)
        syncUploadLiveActivity()
        Task { await uploadPendingTasks() }
    }

    // MARK: - File Selection

    @MainActor
    func handleSelectedFiles(_ urls: [URL]) {
        var tasks: [FileUploadTask] = []

        for url in urls {
#if os(macOS)
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey, .nameKey])
            let fileName = resourceValues?.name ?? url.lastPathComponent
            let fileSize = Int64(resourceValues?.fileSize ?? 0)

            // Save a security-scoped bookmark while we still have access,
            // so uploadSingleFile can re-open the file later on a background task.
            let bookmark = try? url.bookmarkData(options: [.withSecurityScope],
                                                 includingResourceValuesForKeys: nil,
                                                 relativeTo: nil)

            let task = FileUploadTask(fileURL: url, fileName: fileName, fileSize: fileSize)
            configureUploadTask(task)
            task.fileBookmark = bookmark
            if !currentPrefix.isEmpty {
                task.uploadKey = currentPrefix + fileName
            }
            tasks.append(task)
#else
            // iOS: files from document picker are already accessible via security scope
            let _ = url.startAccessingSecurityScopedResource()
            let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey, .nameKey])
            let fileName = resourceValues?.name ?? url.lastPathComponent
            let fileSize = Int64(resourceValues?.fileSize ?? 0)

            let task = FileUploadTask(fileURL: url, fileName: fileName, fileSize: fileSize)
            configureUploadTask(task)
            if !currentPrefix.isEmpty {
                task.uploadKey = currentPrefix + fileName
            }
            tasks.append(task)
#endif
        }

        guard !tasks.isEmpty else { return }
        uploadTasks.append(contentsOf: tasks)
        syncUploadLiveActivity()
        Task { await uploadPendingTasks() }
    }

    @MainActor
    func handleSelectedFolders(_ urls: [URL]) {
        handleDroppedURLs(urls)
    }

    @MainActor
    func presentFilePicker() {
#if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.item]
        panel.begin { [weak self] response in
            guard response == .OK, let self else { return }
            Task { @MainActor in
                self.handleSelectedFiles(panel.urls)
            }
        }
#else
        showFileImporter = true
#endif
    }

    // MARK: - Share Inbox (iOS only)

#if os(iOS)
    /// Reads any files queued by the Share Extension from the shared App Group container
    /// and uploads them. Called at launch.
    func processShareInbox() {
        let appGroupID = "group.fiaxe.r2Vault"
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let pendingStrings = defaults.stringArray(forKey: "pendingShareURLs"),
              !pendingStrings.isEmpty else { return }

        // Clear the queue immediately so we don't re-process on the next launch
        defaults.removeObject(forKey: "pendingShareURLs")

        let urls = pendingStrings.compactMap { URL(string: $0) }
        guard !urls.isEmpty else { return }

        Task { @MainActor in
            // Wait briefly for credentials to be usable after launch
            try? await Task.sleep(for: .seconds(1))
            handleDroppedURLs(urls)
        }
    }
#endif

    // MARK: - Upload

    private func uploadPendingTasks() async {
        guard let credentials else {
            showError("Please configure R2 credentials in Settings first.")
            return
        }

        let pending = uploadTasks.filter { $0.status == .pending }
        await withTaskGroup(of: Void.self) { group in
            for uploadTask in pending {
                // Create and store the task handle on MainActor before it runs,
                // so the cancel button can reach it immediately.
                let handle = Task {
                    await self.uploadSingleFile(uploadTask, credentials: credentials)
                }
                await MainActor.run { uploadTask.uploadTask = handle }
                group.addTask {
                    await handle.value
                    await MainActor.run { uploadTask.uploadTask = nil }
                }
            }
        }
    }

    private func uploadSingleFile(_ uploadTask: FileUploadTask, credentials: R2Credentials) async {
        uploadTask.status = .uploading
        uploadTask.progress = 0

        let fileURL = uploadTask.fileURL

#if os(macOS)
        // Re-establish access to the parent folder bookmark (folder uploads)
        var folderURL: URL?
        var folderAccessing = false
        if let bookmark = uploadTask.parentFolderBookmark {
            var isStale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark,
                                       options: [.withSecurityScope],
                                       relativeTo: nil,
                                       bookmarkDataIsStale: &isStale) {
                folderURL = resolved
                folderAccessing = resolved.startAccessingSecurityScopedResource()
            }
        }
        defer { if folderAccessing { folderURL?.stopAccessingSecurityScopedResource() } }

        // Re-establish access to the individual file via its bookmark (file picker uploads),
        // or fall back to a direct security-scoped access call on the stored URL.
        var resolvedFileURL = fileURL
        var fileAccessing = false
        if let bookmark = uploadTask.fileBookmark {
            var isStale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark,
                                       options: [.withSecurityScope],
                                       relativeTo: nil,
                                       bookmarkDataIsStale: &isStale) {
                resolvedFileURL = resolved
                fileAccessing = resolved.startAccessingSecurityScopedResource()
            }
        } else {
            fileAccessing = fileURL.startAccessingSecurityScopedResource()
        }
        defer { if fileAccessing { resolvedFileURL.stopAccessingSecurityScopedResource() } }
#else
        let resolvedFileURL = fileURL
#endif

        let contentType = mimeType(for: resolvedFileURL)
        // Use explicit upload key (folder-aware) or fall back to random-prefix key
        let key: String
        if let explicitKey = uploadTask.uploadKey, !explicitKey.isEmpty {
            key = explicitKey
        } else {
            let keyPrefix = UUID().uuidString.prefix(8)
            key = "\(keyPrefix)-\(uploadTask.fileName)"
        }

        do {
            let result = try await R2UploadService.upload(
                fileURL: resolvedFileURL,
                credentials: credentials,
                key: key,
                contentType: contentType,
                onProgress: { [weak uploadTask] sent, total in
                    guard let uploadTask else { return }
                    uploadTask.progress = total > 0 ? Double(sent) / Double(total) : 0
                }
            )

            if (200...299).contains(result.httpStatusCode) {
                let publicURL = credentials.publicURL(forKey: key)
                uploadTask.resultURL = publicURL
                uploadTask.progress = 1.0
                uploadTask.status = .completed
                invalidateBrowserCache()
                loadCurrentFolder()

                let item = UploadItem(
                    fileName: uploadTask.fileName,
                    fileSize: uploadTask.fileSize,
                    r2Key: key,
                    publicURL: publicURL,
                    bucketName: credentials.bucketName
                )
                historyStore.add(item)
                copyToClipboard(publicURL.absoluteString)
                clipboardToastFileName = uploadTask.fileName
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2.5))
                    if clipboardToastFileName == uploadTask.fileName {
                        clipboardToastFileName = nil
                    }
                }
            } else {
                let body = String(data: result.responseBody, encoding: .utf8) ?? "Unknown error"
                uploadTask.status = .failed
                uploadTask.errorMessage = "HTTP \(result.httpStatusCode): \(body)"
            }
        } catch is CancellationError {
            if uploadTask.status != .cancelled {
                uploadTask.status = .cancelled
            }
        } catch {
            uploadTask.status = .failed
            uploadTask.errorMessage = error.localizedDescription
        }
    }

    // MARK: - Download

    /// Returns a presigned download URL for the given object, or nil if credentials are missing.
    func presignedDownloadURL(for object: R2Object) -> URL? {
        guard let credentials else { return nil }
        return AWSV4Signer.presignedURL(for: object.key, credentials: credentials)
    }

    func downloadToDestination(from remoteURL: URL, dest: URL) {
#if os(iOS)
        BackgroundDownloadService.shared.download(
            from: remoteURL,
            to: dest,
            onSuccess: { _ in },
            onFailure: { [weak self] error in
                self?.showError("Download failed: \(error.localizedDescription)")
            }
        )
#else
        Task {
            do {
                let (tmpURL, _) = try await URLSession.shared.download(from: remoteURL)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmpURL, to: dest)
            } catch {
                await MainActor.run { showError("Download failed: \(error.localizedDescription)") }
            }
        }
#endif
    }

    /// Downloads a history item to the user's Downloads folder via a presigned URL.
    func downloadHistoryItem(_ item: UploadItem) {
        guard let credentials else { return }
        guard let presigned = AWSV4Signer.presignedURL(for: item.r2Key, credentials: credentials) else { return }
        let dest = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(item.fileName)
        downloadToDestination(from: presigned, dest: dest)
    }

    /// Deletes a history item from R2 and removes it from local history.
    func deleteHistoryItem(_ item: UploadItem) {
        guard let credentials else { return }
        // Remove from local history immediately
        if let idx = historyStore.items.firstIndex(where: { $0.id == item.id }) {
            historyStore.items.remove(at: idx)
        }
        // Delete from R2 in background
        Task {
            try? await R2BrowseService.deleteObject(credentials: credentials, key: item.r2Key)
            await MainActor.run {
                invalidateBrowserCache()
                loadCurrentFolder()
            }
        }
    }

    // MARK: - Dashboard / Bucket Scan

    func scanBucket() {
        guard let credentials else {
            scanError = "No credentials configured."
            return
        }
        isScanning = true
        scanError = nil
        Task {
            do {
                let result = try await R2BrowseService.listObjects(credentials: credentials, prefix: "")
                let rootFolders = result.folders

                // Also do a full recursive listing for complete stats
                let allKeys = try await Self.listAllObjectsWithDetails(credentials: credentials)

                var stats = BucketStats()
                stats.totalFolders = rootFolders.count
                stats.totalFiles = allKeys.count
                stats.totalSize = allKeys.reduce(0) { $0 + $1.size }

                // Categorize files
                for file in allKeys {
                    let ext = (file.key as NSString).pathExtension
                    let category = BucketStats.FileCategory.categorize(extension: ext)
                    var catStats = stats.filesByType[category] ?? BucketStats.CategoryStats()
                    catStats.count += 1
                    catStats.totalSize += file.size
                    stats.filesByType[category] = catStats
                }

                // Top 10 largest files
                stats.largestFiles = allKeys
                    .sorted { $0.size > $1.size }
                    .prefix(10)
                    .map { BucketStats.FileInfo(key: $0.key, size: $0.size, lastModified: $0.lastModified) }

                // 5 most recent files
                stats.recentFiles = allKeys
                    .sorted { ($0.lastModified ?? .distantPast) > ($1.lastModified ?? .distantPast) }
                    .prefix(5)
                    .map { BucketStats.FileInfo(key: $0.key, size: $0.size, lastModified: $0.lastModified) }

                stats.lastScanned = Date()
                bucketStats = stats
                isScanning = false
            } catch {
                scanError = error.localizedDescription
                isScanning = false
            }
        }
    }

    /// Lists all objects recursively with size and date details using paginated ListObjectsV2 (no delimiter).
    private static func listAllObjectsWithDetails(credentials: R2Credentials, prefix: String = "") async throws -> [R2Object] {
        var allObjects: [R2Object] = []
        var continuationToken: String? = nil

        repeat {
            let baseURL = credentials.endpoint.appendingPathComponent(credentials.bucketName)
            var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "list-type", value: "2"),
            ]
            if !prefix.isEmpty {
                queryItems.append(URLQueryItem(name: "prefix", value: prefix))
            }
            if let token = continuationToken {
                queryItems.append(URLQueryItem(name: "continuation-token", value: token))
            }
            comps.queryItems = queryItems

            guard let url = comps.url else { throw URLError(.badURL) }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            let signed = AWSV4Signer.sign(request: request, credentials: credentials,
                                          payloadHash: AWSV4Signer.sha256Hex(""))

            let (data, response) = try await URLSession.shared.data(for: signed)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                let body = String(data: data, encoding: .utf8) ?? ""
                throw R2BrowseError.httpError(code, body)
            }

            let parser = FullListParser()
            let result = try parser.parse(data: data)
            allObjects.append(contentsOf: result.objects.filter { !$0.key.hasSuffix("/") })
            continuationToken = result.isTruncated ? result.nextContinuationToken : nil
        } while continuationToken != nil

        return allObjects
    }

    // MARK: - Updates

    /// - Parameter userInitiated: Pass `true` when triggered by the user (e.g. menu item).
    ///   Shows the sheet even when already up to date. Automatic startup checks only show
    ///   the sheet when a new version is actually available.
    func checkForUpdates(userInitiated: Bool = false) {
        guard !updateStatus.isChecking else { return }
        updateStatus = .checking
        Task {
            do {
                if let release = try await UpdateService.checkForUpdate() {
                    updateStatus = .available(release)
                    showUpdateSheet = true
                } else {
                    updateStatus = .upToDate
                    if userInitiated { showUpdateSheet = true }
                }
            } catch {
                updateStatus = .failed(error.localizedDescription)
                if userInitiated { showUpdateSheet = true }
            }
        }
    }

    // MARK: - Clipboard

    func copyToClipboard(_ string: String) {
#if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
#else
        UIPasteboard.general.string = string
#endif
    }

    // MARK: - Queue Management

    @MainActor
    func removeCompletedAndFailed() {
        uploadTasks.removeAll { $0.status == .completed || $0.status == .failed }
        syncUploadLiveActivity()
    }

    // MARK: - Helpers

    private func showError(_ message: String) {
        alertMessage = message
        showAlert = true
    }

    private func configureUploadTask(_ task: FileUploadTask) {
        task.onStateChange = { [weak self] in
            self?.syncUploadLiveActivity()
        }
    }

    private func syncUploadLiveActivity() {
#if os(iOS)
        if #available(iOS 16.1, *) {
            UploadLiveActivityService.shared.sync(tasks: uploadTasks)
        }
#endif
    }

    private func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension) {
            return type.preferredMIMEType ?? "application/octet-stream"
        }
        return "application/octet-stream"
    }
}
