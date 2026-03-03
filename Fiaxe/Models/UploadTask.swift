import Foundation

/// Represents a pending or in-progress upload in the upload queue
@Observable
final class FileUploadTask: Identifiable {
    let id: UUID
    let fileName: String
    let fileSize: Int64
    let fileURL: URL

    var progress: Double = 0  // 0.0 – 1.0
    var status: Status = .pending
    var errorMessage: String?
    var resultURL: URL?
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
    }

    init(fileURL: URL, fileName: String, fileSize: Int64) {
        self.id = UUID()
        self.fileURL = fileURL
        self.fileName = fileName
        self.fileSize = fileSize
    }
}
