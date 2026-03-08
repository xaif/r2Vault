import Foundation

/// A completed upload entry stored in history
struct UploadItem: Identifiable, Codable, Sendable {
    let id: UUID
    let fileName: String
    let fileSize: Int64
    let r2Key: String
    let uploadDate: Date
    let publicURL: URL
    let bucketName: String
    let credentialID: UUID?
    let accountId: String?

    init(
        fileName: String,
        fileSize: Int64,
        r2Key: String,
        publicURL: URL,
        bucketName: String,
        credentialID: UUID? = nil,
        accountId: String? = nil
    ) {
        self.id = UUID()
        self.fileName = fileName
        self.fileSize = fileSize
        self.r2Key = r2Key
        self.uploadDate = Date()
        self.publicURL = publicURL
        self.bucketName = bucketName
        self.credentialID = credentialID
        self.accountId = accountId
    }

    var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    func matches(credentials: R2Credentials) -> Bool {
        if let credentialID {
            return credentialID == credentials.id
        }

        if let accountId {
            return accountId == credentials.accountId && bucketName == credentials.bucketName
        }

        return bucketName == credentials.bucketName
    }
}
