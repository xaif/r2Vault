import Foundation
import AppKit
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
    var alertMessage: String?
    var showAlert = false

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
    var filterText: String = ""
    /// Selected object IDs for multi-select operations
    var selectedObjectIDs: Set<UUID> = []


    /// All items merged (folders first by default, then files), sorted and filtered
    var allBrowserItems: [R2Object] {
        let combined = browserFolders + browserObjects
        let filtered: [R2Object]
        if filterText.isEmpty {
            filtered = combined
        } else {
            filtered = combined.filter { $0.name.localizedCaseInsensitiveContains(filterText) }
        }
        return filtered.sorted { a, b in
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
        checkForUpdates()
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

    func loadCurrentFolder() {
        guard let credentials else {
            browserError = "Please configure R2 credentials in Settings (⌘,)."
            return
        }
        isBrowsing = true
        browserError = nil
        Task {
            do {
                let result = try await R2BrowseService.listObjects(
                    credentials: credentials,
                    prefix: currentPrefix
                )
                browserObjects = result.objects
                    .filter { !$0.key.hasSuffix("/") }   // skip zero-byte folder markers
                browserFolders = result.folders
                isBrowsing = false
            } catch {
                browserError = error.localizedDescription
                isBrowsing = false
            }
        }
    }

    func navigateToFolder(_ object: R2Object) {
        backStack.append(currentPrefix)
        forwardStack.removeAll()
        currentPrefix = object.key
        loadCurrentFolder()
    }

    /// Navigate to a path segment by index into `pathSegments`.
    func navigateToSegment(_ index: Int) {
        let segments = pathSegments
        guard index < segments.count else { return }
        let newSegments = Array(segments.prefix(index + 1))
        let newPrefix = newSegments.joined(separator: "/") + "/"
        guard newPrefix != currentPrefix else { return }
        backStack.append(currentPrefix)
        forwardStack.removeAll()
        currentPrefix = newPrefix
        loadCurrentFolder()
    }

    func navigateToRoot() {
        guard !currentPrefix.isEmpty else { return }
        backStack.append(currentPrefix)
        forwardStack.removeAll()
        currentPrefix = ""
        loadCurrentFolder()
    }

    func navigateBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(currentPrefix)
        currentPrefix = previous
        loadCurrentFolder()
    }

    func navigateForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(currentPrefix)
        currentPrefix = next
        loadCurrentFolder()
    }

    func createFolder(name: String) async {
        guard let credentials else { return }
        let folderKey = currentPrefix + name + "/"
        do {
            try await R2BrowseService.createFolder(credentials: credentials, folderKey: folderKey)
            loadCurrentFolder()
        } catch {
            showError("Failed to create folder: \(error.localizedDescription)")
        }
    }

    func deleteObject(_ object: R2Object) async {
        guard let credentials else { return }
        do {
            try await R2BrowseService.deleteObject(credentials: credentials, key: object.key)
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
                    try? await R2BrowseService.deleteObject(credentials: credentials, key: object.key)
                }
            }
        }
        loadCurrentFolder()
    }

    func selectAll() {
        selectedObjectIDs = Set(allBrowserItems.map(\.id))
    }

    func clearSelection() {
        selectedObjectIDs.removeAll()
    }

    // MARK: - Drag-and-Drop

    /// Handles URLs dropped from Finder. Directories are recursively enumerated.
    func handleDroppedURLs(_ urls: [URL]) {
        var tasks: [FileUploadTask] = []

        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            guard exists else { continue }

            if isDirectory.boolValue {
                // Recursively enumerate directory contents
                let dirName = url.lastPathComponent
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
                    task.uploadKey = r2Key
                    task.parentFolderBookmark = folderBookmark
                    tasks.append(task)
                }
            } else {
                // Single file — upload into current prefix
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .nameKey])
                let fileName = values?.name ?? url.lastPathComponent
                let fileSize = Int64(values?.fileSize ?? 0)
                let r2Key = currentPrefix + fileName

                let task = FileUploadTask(fileURL: url, fileName: fileName, fileSize: fileSize)
                task.uploadKey = r2Key
                tasks.append(task)
            }
        }

        guard !tasks.isEmpty else { return }
        uploadTasks.append(contentsOf: tasks)
        Task { await uploadPendingTasks() }
    }

    // MARK: - File Selection

    func handleSelectedFiles(_ urls: [URL]) {
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey, .nameKey])
            let fileName = resourceValues?.name ?? url.lastPathComponent
            let fileSize = Int64(resourceValues?.fileSize ?? 0)

            let task = FileUploadTask(fileURL: url, fileName: fileName, fileSize: fileSize)
            // When browsing a folder, upload into that folder
            if !currentPrefix.isEmpty {
                task.uploadKey = currentPrefix + fileName
            }
            uploadTasks.append(task)
        }

        Task {
            await uploadPendingTasks()
        }
    }

    func handleSelectedFolders(_ urls: [URL]) {
        handleDroppedURLs(urls)
    }

    // MARK: - Upload

    private func uploadPendingTasks() async {
        guard let credentials else {
            showError("Please configure R2 credentials in Settings first (Cmd+,).")
            return
        }

        let pending = uploadTasks.filter { $0.status == .pending }
        await withTaskGroup(of: Void.self) { group in
            for task in pending {
                group.addTask {
                    await self.uploadSingleFile(task, credentials: credentials)
                }
            }
        }
    }

    private func uploadSingleFile(_ uploadTask: FileUploadTask, credentials: R2Credentials) async {
        uploadTask.status = .uploading
        uploadTask.progress = 0

        let fileURL = uploadTask.fileURL

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

        let accessing = fileURL.startAccessingSecurityScopedResource()
        defer { if accessing { fileURL.stopAccessingSecurityScopedResource() } }

        let contentType = mimeType(for: fileURL)
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
                fileURL: fileURL,
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

                let item = UploadItem(
                    fileName: uploadTask.fileName,
                    fileSize: uploadTask.fileSize,
                    r2Key: key,
                    publicURL: publicURL
                )
                historyStore.add(item)
                copyToClipboard(publicURL.absoluteString)
            } else {
                let body = String(data: result.responseBody, encoding: .utf8) ?? "Unknown error"
                uploadTask.status = .failed
                uploadTask.errorMessage = "HTTP \(result.httpStatusCode): \(body)"
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
        Task {
            do {
                let (tmpURL, _) = try await URLSession.shared.download(from: remoteURL)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmpURL, to: dest)
            } catch {
                await MainActor.run { showError("Download failed: \(error.localizedDescription)") }
            }
        }
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
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    // MARK: - Queue Management

    func removeCompletedAndFailed() {
        uploadTasks.removeAll { $0.status == .completed || $0.status == .failed }
    }

    // MARK: - Helpers

    private func showError(_ message: String) {
        alertMessage = message
        showAlert = true
    }

    private func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension) {
            return type.preferredMIMEType ?? "application/octet-stream"
        }
        return "application/octet-stream"
    }
}
