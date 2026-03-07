import Foundation

/// Represents a pending or in-progress upload in the upload queue
@Observable
final class FileUploadTask: Identifiable {
    let id: UUID
    let fileName: String
    let fileSize: Int64
    let fileURL: URL

    /// 0.0 – 1.0
    var progress: Double = 0 {
        didSet { notifyStateChange() }
    }
    var status: Status = .pending {
        didSet { notifyStateChange() }
    }
    var errorMessage: String? {
        didSet { notifyStateChange() }
    }
    var resultURL: URL? {
        didSet { notifyStateChange() }
    }
    /// When set, used as the full R2 key instead of generating a random-prefix key.
    /// Used for folder-aware uploads from the browser.
    var uploadKey: String?
    /// Security-scoped bookmark for a parent folder (used when uploading folders).
    var parentFolderBookmark: Data?
    /// Security-scoped bookmark for the file itself (used when uploading individual files via file picker).
    var fileBookmark: Data?

    enum Status: Sendable {
        case pending
        case uploading
        case completed
        case failed
        case cancelled
    }

    /// The running upload task — held so it can be cancelled.
    var uploadTask: Task<Void, Never>?
    var onStateChange: (() -> Void)?

    init(fileURL: URL, fileName: String, fileSize: Int64) {
        self.id = UUID()
        self.fileURL = fileURL
        self.fileName = fileName
        self.fileSize = fileSize
    }

    func cancel() {
        uploadTask?.cancel()
        uploadTask = nil
        status = .cancelled
    }

    private func notifyStateChange() {
        guard let onStateChange else { return }
        // Call directly if already on MainActor, otherwise hop to it.
        if Thread.isMainThread {
            onStateChange()
        } else {
            Task { @MainActor in onStateChange() }
        }
    }
}
