import Foundation
import CryptoKit

/// Handles file uploads to Cloudflare R2 using the S3-compatible API
nonisolated enum R2UploadService {

    struct UploadResult: Sendable {
        let httpStatusCode: Int
        let responseBody: Data
    }

    /// Uploads a file to R2 via a signed PUT request.
    /// - Parameters:
    ///   - fileURL: Security-scoped URL of the file to upload
    ///   - credentials: R2 credentials
    ///   - key: Object key in the bucket (e.g., "abc12345-photo.jpg")
    ///   - contentType: MIME type of the file
    ///   - onProgress: Progress callback fired on the main actor (bytesSent, totalBytes)
    static func upload(
        fileURL: URL,
        credentials: R2Credentials,
        key: String,
        contentType: String,
        onProgress: @MainActor @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> UploadResult {
        let url = await credentials.endpoint
            .appendingPathComponent(credentials.bucketName)
            .appendingPathComponent(key)

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
        request.setValue("\(fileSize)", forHTTPHeaderField: "Content-Length")

        let signedRequest = AWSV4Signer.sign(
            request: request,
            credentials: credentials,
            payloadHash: "UNSIGNED-PAYLOAD"
        )

        let delegate = UploadProgressDelegate(onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.upload(for: signedRequest, fromFile: fileURL)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        return UploadResult(httpStatusCode: statusCode, responseBody: data)
    }

    /// Performs a HEAD request to verify connectivity and credentials.
    static func testConnection(credentials: R2Credentials) async throws -> Bool {
        let url = await credentials.endpoint.appendingPathComponent(credentials.bucketName)
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"

        let emptyHash = SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined()
        let signedRequest = AWSV4Signer.sign(
            request: request,
            credentials: credentials,
            payloadHash: emptyHash
        )

        let (_, response) = try await URLSession.shared.data(for: signedRequest)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        return statusCode == 200
    }
}

// MARK: - Progress delegate

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @MainActor @Sendable (Int64, Int64) -> Void

    init(onProgress: @MainActor @escaping @Sendable (Int64, Int64) -> Void) {
        self.onProgress = onProgress
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        let handler = onProgress
        let sent = totalBytesSent
        let total = totalBytesExpectedToSend
        Task { @MainActor in
            handler(sent, total)
        }
    }
}
