import Foundation
import CryptoKit

/// A multipart upload R2 has started for `key`, with the parts it already holds.
struct PendingUpload: Sendable, Equatable {
    let key: String
    let uploadID: String
    let size: Int64
    let partSize: Int64
    var parts: [Int: UploadedPart] = [:]
}

struct UploadedPart: Sendable, Equatable {
    let etag: String
    /// MD5 of the bytes sent, to check the file still has them before the part is reused.
    let md5: String
}

/// Remembers multipart uploads between attempts, so one cut off by a network drop carries on
/// from the parts R2 already has instead of starting over.
protocol UploadJournal: Sendable {
    func pendingUpload(key: String) -> PendingUpload?
    func startUpload(_ upload: PendingUpload)
    func recordPart(key: String, uploadID: String, number: Int, part: UploadedPart)
    func finishUpload(key: String)
}

/// A small async S3 client covering the calls the Finder drive needs.
/// Requests are signed with the app's `AWSV4Signer`.
struct R2Client: Sendable {

    struct Object: Sendable {
        let key: String
        let size: Int64
        let etag: String
        let lastModified: Date?
    }

    struct Listing: Sendable {
        var objects: [Object] = []
        /// Folder prefixes (CommonPrefixes), each ending in "/".
        var prefixes: [String] = []
    }

    struct ObjectInfo: Sendable {
        let size: Int64
        let etag: String
        let lastModified: Date?
    }

    enum ClientError: Error {
        case http(status: Int, code: String?, message: String)
        case invalidResponse
    }

    let credentials: R2Credentials
    let session: URLSession

    /// Uploads at or below this size use a single PUT; larger ones go up in parallel parts.
    static let singlePutLimit: Int64 = 16 * 1024 * 1024
    /// Objects above this size are copied with UploadPartCopy (CopyObject tops out at 5 GiB).
    static let singleCopyLimit: Int64 = 4 * 1024 * 1024 * 1024

    // MARK: - Listing

    /// Lists everything under `prefix`, following continuation tokens.
    /// With a delimiter the listing is one level deep; without, it is recursive.
    func list(prefix: String, delimiter: String? = "/", maxKeys: Int? = nil) async throws -> Listing {
        var listing = Listing()
        var token: String?
        repeat {
            var query = [("list-type", "2"), ("prefix", prefix)]
            if let delimiter { query.append(("delimiter", delimiter)) }
            if let maxKeys { query.append(("max-keys", String(maxKeys))) }
            if let token { query.append(("continuation-token", token)) }

            let request = makeRequest(method: "GET", key: nil, query: query)
            let (data, _) = try await send(request)
            let page = try ListParser.parse(data)
            listing.objects += page.listing.objects
            listing.prefixes += page.listing.prefixes
            token = page.isTruncated ? page.nextToken : nil
            if maxKeys != nil { break }
        } while token != nil
        return listing
    }

    /// True if any object exists at or under `prefix`.
    func prefixExists(_ prefix: String) async throws -> Bool {
        let listing = try await list(prefix: prefix, delimiter: nil, maxKeys: 1)
        return !listing.objects.isEmpty
    }

    // MARK: - Metadata

    /// Returns nil when the object does not exist.
    func head(key: String) async throws -> ObjectInfo? {
        let request = makeRequest(method: "HEAD", key: key)
        do {
            let (_, response) = try await send(request)
            return Self.info(from: response)
        } catch ClientError.http(let status, _, _) where status == 404 {
            return nil
        }
    }

    // MARK: - Download

    /// Downloads an object (or a byte range of it) to a temporary file and returns its location.
    /// The caller owns the returned file.
    func download(
        key: String,
        range: Range<Int64>? = nil,
        ifMatch etag: String? = nil,
        progress: Progress? = nil
    ) async throws -> (file: URL, info: ObjectInfo) {
        var headers: [String: String] = [:]
        if let range { headers["Range"] = "bytes=\(range.lowerBound)-\(range.upperBound - 1)" }
        if let etag, !etag.isEmpty { headers["If-Match"] = "\"\(etag)\"" }
        let request = makeRequest(method: "GET", key: key, headers: headers)

        let (file, response) = try await downloadTask(request, progress: progress)
        guard (200...299).contains(response.statusCode) else {
            let body = (try? Data(contentsOf: file)) ?? Data()
            try? FileManager.default.removeItem(at: file)
            throw Self.httpError(status: response.statusCode, body: body)
        }
        var info = Self.info(from: response)
        // For ranged responses, Content-Length is the range size; the full size is in Content-Range.
        if let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
           let total = contentRange.split(separator: "/").last.flatMap({ Int64($0) }) {
            info = ObjectInfo(size: total, etag: info.etag, lastModified: info.lastModified)
        }
        return (file, info)
    }

    /// Downloads `range` of an object into `file` (which must exist), with each byte at its real
    /// offset. The range is split across up to `connections` parallel requests, which is
    /// considerably faster than one stream on most links.
    func download(
        key: String,
        range: Range<Int64>,
        ifMatch etag: String?,
        into file: URL,
        connections: Int,
        progress: Progress? = nil
    ) async throws -> ObjectInfo {
        let length = range.upperBound - range.lowerBound
        let minimumPart: Int64 = 4 * 1024 * 1024
        let count = max(1, min(Int64(connections), length / minimumPart))
        let partSize = ((length + count - 1) / count + 65_535) / 65_536 * 65_536
        var parts: [Range<Int64>] = []
        var start = range.lowerBound
        while start < range.upperBound {
            let end = min(start + partSize, range.upperBound)
            parts.append(start..<end)
            start = end
        }

        return try await withThrowingTaskGroup(of: ObjectInfo.self) { group in
            for part in parts {
                group.addTask {
                    let (temporary, info) = try await download(key: key, range: part, ifMatch: etag)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    // A server that ignores Range sends the whole object; take our slice of it.
                    let received = (try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                    let partLength = part.upperBound - part.lowerBound
                    let sourceOffset: Int64 = received == partLength ? 0 : part.lowerBound
                    guard received == partLength || received == info.size else { throw ClientError.invalidResponse }
                    try Self.copy(from: temporary, at: sourceOffset, length: partLength, into: file, at: part.lowerBound)
                    progress?.completedUnitCount += partLength
                    return info
                }
            }
            var first: ObjectInfo?
            for try await info in group where first == nil {
                first = info
            }
            return first!
        }
    }

    private static func copy(from source: URL, at sourceOffset: Int64, length: Int64, into destination: URL, at offset: Int64) throws {
        let reader = try FileHandle(forReadingFrom: source)
        let writer = try FileHandle(forWritingTo: destination)
        defer {
            try? reader.close()
            try? writer.close()
        }
        try reader.seek(toOffset: UInt64(sourceOffset))
        try writer.seek(toOffset: UInt64(offset))
        var remaining = length
        while remaining > 0, let chunk = try reader.read(upToCount: Int(min(remaining, 4 * 1024 * 1024))), !chunk.isEmpty {
            try writer.write(contentsOf: chunk)
            remaining -= Int64(chunk.count)
        }
    }

    // MARK: - Upload

    /// Creates a zero-byte "folder/" marker object.
    func putFolderMarker(key: String) async throws -> ObjectInfo {
        var request = makeRequest(
            method: "PUT",
            key: key,
            headers: ["Content-Length": "0", "Content-Type": "application/x-directory"],
            payloadHash: AWSV4Signer.sha256Hex("")
        )
        request.httpBody = Data()
        let (_, response) = try await send(request)
        return Self.info(from: response, knownSize: 0)
    }

    /// Uploads a local file, switching to multipart for large files. With a `journal`, a
    /// multipart upload interrupted by a network drop stays open on R2, and the next upload of
    /// the same key reuses the parts R2 already has.
    func upload(fileURL: URL, key: String, contentType: String, progress: Progress? = nil,
                journal: UploadJournal? = nil) async throws -> ObjectInfo {
        let size = Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        if size <= Self.singlePutLimit {
            let request = makeRequest(
                method: "PUT",
                key: key,
                headers: ["Content-Length": String(size), "Content-Type": contentType]
            )
            let (_, response) = try await uploadTask(request, fromFile: fileURL, progress: progress, pendingUnits: size)
            return Self.info(from: response, knownSize: size)
        }
        return try await multipartUpload(fileURL: fileURL, size: size, key: key, contentType: contentType,
                                         progress: progress, journal: journal)
    }

    private func multipartUpload(
        fileURL: URL,
        size: Int64,
        key: String,
        contentType: String,
        progress: Progress?,
        journal: UploadJournal?,
        isRestart: Bool = false
    ) async throws -> ObjectInfo {
        let partSize = Self.multipartPartSize(for: size)
        let partCount = Int((size + partSize - 1) / partSize)
        func range(of number: Int) -> (offset: Int64, length: Int64) {
            let offset = Int64(number - 1) * partSize
            return (offset, min(partSize, size - offset))
        }

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        // Carry on with an earlier attempt at this key when it was for a file of the same size.
        // A part is reused only if the file still holds the bytes that were sent for it.
        var etags = [Int: String]()
        let uploadID: String
        let pending = journal?.pendingUpload(key: key)
        if let pending, pending.size == size, pending.partSize == partSize {
            uploadID = pending.uploadID
            for (number, part) in pending.parts where number <= partCount {
                let (offset, length) = range(of: number)
                if try Self.md5(of: handle, offset: offset, length: length) == part.md5 {
                    etags[number] = part.etag
                }
            }
            progress?.completedUnitCount += etags.keys.reduce(0) { $0 + range(of: $1).length }
        } else {
            if let pending {
                try? await abortMultipartUpload(key: key, uploadID: pending.uploadID)
                journal?.finishUpload(key: key)
            }
            uploadID = try await createMultipartUpload(key: key, contentType: contentType)
            journal?.startUpload(PendingUpload(key: key, uploadID: uploadID, size: size, partSize: partSize))
        }

        do {
            let missing = (1...partCount).filter { etags[$0] == nil }
            // Upload up to 4 parts at a time; each part is read into memory just before it is sent.
            try await withThrowingTaskGroup(of: (Int, String).self) { group in
                var next = 0
                func addPart(_ number: Int) throws {
                    let (offset, length) = range(of: number)
                    try handle.seek(toOffset: UInt64(offset))
                    guard let body = try handle.read(upToCount: Int(length)), body.count == Int(length) else {
                        throw CocoaError(.fileReadUnknown)
                    }
                    let md5 = Self.hex(Insecure.MD5.hash(data: body))
                    group.addTask {
                        let request = makeRequest(
                            method: "PUT",
                            key: key,
                            query: [("partNumber", String(number)), ("uploadId", uploadID)],
                            headers: ["Content-Length": String(body.count)]
                        )
                        let (_, response) = try await uploadTask(request, fromData: body, progress: progress, pendingUnits: Int64(body.count))
                        guard let etag = response.value(forHTTPHeaderField: "ETag") else { throw ClientError.invalidResponse }
                        journal?.recordPart(key: key, uploadID: uploadID, number: number, part: UploadedPart(etag: etag, md5: md5))
                        return (number, etag)
                    }
                }
                while next < min(4, missing.count) { try addPart(missing[next]); next += 1 }
                while let (number, etag) = try await group.next() {
                    etags[number] = etag
                    if next < missing.count { try addPart(missing[next]); next += 1 }
                }
            }
            let info = try await completeMultipartUpload(key: key, uploadID: uploadID, etags: etags, size: size)
            journal?.finishUpload(key: key)
            return info
        } catch ClientError.http(_, "NoSuchUpload", _) where !isRestart {
            // R2 no longer has the upload (it expires unfinished ones): start over, once.
            journal?.finishUpload(key: key)
            return try await multipartUpload(fileURL: fileURL, size: size, key: key, contentType: contentType,
                                             progress: progress, journal: journal, isRestart: true)
        } catch {
            // Keep the upload for the next attempt unless the failure means it can't succeed.
            if journal == nil || !Self.isTransient(error) {
                try? await abortMultipartUpload(key: key, uploadID: uploadID)
                journal?.finishUpload(key: key)
            }
            throw error
        }
    }

    /// Failures a later attempt can get past: dropped connections, timeouts, cancellations,
    /// and server-side errors.
    static func isTransient(_ error: Error) -> Bool {
        switch error {
        case is CancellationError, is URLError, ClientError.invalidResponse:
            return true
        case ClientError.http(let status, _, _):
            return status >= 500 || status == 408 || status == 429
        default:
            return false
        }
    }

    /// MD5 of `length` bytes of a file starting at `offset`, read in chunks.
    private static func md5(of handle: FileHandle, offset: Int64, length: Int64) throws -> String {
        try handle.seek(toOffset: UInt64(offset))
        var hasher = Insecure.MD5()
        var remaining = length
        while remaining > 0 {
            guard let chunk = try handle.read(upToCount: Int(min(remaining, 8 << 20))), !chunk.isEmpty else {
                return ""
            }
            hasher.update(data: chunk)
            remaining -= Int64(chunk.count)
        }
        return hex(hasher.finalize())
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Part size for a multipart upload of `size` bytes. R2 needs equal-sized parts (except the
    /// last) and allows up to 10,000 of them.
    static func multipartPartSize(for size: Int64) -> Int64 {
        let minimumPart: Int64 = 16 * 1024 * 1024
        return max(minimumPart, ((size / 9_000) / (1024 * 1024) + 1) * 1024 * 1024)
    }

    private func createMultipartUpload(key: String, contentType: String) async throws -> String {
        let request = makeRequest(
            method: "POST",
            key: key,
            query: [("uploads", "")],
            headers: ["Content-Type": contentType],
            payloadHash: AWSV4Signer.sha256Hex("")
        )
        let (data, _) = try await send(request)
        guard let uploadID = XMLValueParser.firstValue(of: "UploadId", in: data) else {
            throw ClientError.invalidResponse
        }
        return uploadID
    }

    private func completeMultipartUpload(key: String, uploadID: String, etags: [Int: String], size: Int64) async throws -> ObjectInfo {
        let parts = etags.keys.sorted().map { number in
            "<Part><PartNumber>\(number)</PartNumber><ETag>\(Self.xmlEscape(etags[number]!))</ETag></Part>"
        }.joined()
        let body = "<CompleteMultipartUpload>\(parts)</CompleteMultipartUpload>"
        var request = makeRequest(
            method: "POST",
            key: key,
            query: [("uploadId", uploadID)],
            headers: ["Content-Type": "application/xml"],
            payloadHash: AWSV4Signer.sha256Hex(body)
        )
        request.httpBody = Data(body.utf8)
        let (data, response) = try await send(request)
        let etag = XMLValueParser.firstValue(of: "ETag", in: data).map(Self.normalizeETag)
            ?? Self.info(from: response).etag
        return ObjectInfo(size: size, etag: etag, lastModified: Date())
    }

    func abortMultipartUpload(key: String, uploadID: String) async throws {
        let request = makeRequest(method: "DELETE", key: key, query: [("uploadId", uploadID)], payloadHash: AWSV4Signer.sha256Hex(""))
        _ = try await send(request)
    }

    // MARK: - Copy & Delete

    /// Server-side copy. Large objects are copied in parts.
    func copy(from sourceKey: String, to destinationKey: String, size: Int64) async throws {
        let source = "/\(credentials.bucketName)/\(Self.encodePath(sourceKey))"
        if size <= Self.singleCopyLimit {
            let request = makeRequest(
                method: "PUT",
                key: destinationKey,
                headers: ["x-amz-copy-source": source],
                payloadHash: AWSV4Signer.sha256Hex("")
            )
            _ = try await send(request)
            return
        }

        let partSize: Int64 = 512 * 1024 * 1024
        let partCount = Int((size + partSize - 1) / partSize)
        let uploadID = try await createMultipartUpload(key: destinationKey, contentType: "application/octet-stream")
        do {
            var etags = [Int: String]()
            for number in 1...partCount {
                let start = Int64(number - 1) * partSize
                let end = min(start + partSize, size) - 1
                let request = makeRequest(
                    method: "PUT",
                    key: destinationKey,
                    query: [("partNumber", String(number)), ("uploadId", uploadID)],
                    headers: ["x-amz-copy-source": source, "x-amz-copy-source-range": "bytes=\(start)-\(end)"],
                    payloadHash: AWSV4Signer.sha256Hex("")
                )
                let (data, _) = try await send(request)
                guard let etag = XMLValueParser.firstValue(of: "ETag", in: data) else { throw ClientError.invalidResponse }
                etags[number] = etag
            }
            _ = try await completeMultipartUpload(key: destinationKey, uploadID: uploadID, etags: etags, size: size)
        } catch {
            try? await abortMultipartUpload(key: destinationKey, uploadID: uploadID)
            throw error
        }
    }

    func delete(key: String) async throws {
        let request = makeRequest(method: "DELETE", key: key, payloadHash: AWSV4Signer.sha256Hex(""))
        do {
            _ = try await send(request)
        } catch ClientError.http(let status, _, _) where status == 404 {
            // Already gone.
        }
    }

    // MARK: - Request plumbing

    private func makeRequest(
        method: String,
        key: String?,
        query: [(String, String)] = [],
        headers: [String: String] = [:],
        payloadHash: String = "UNSIGNED-PAYLOAD"
    ) -> URLRequest {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = credentials.endpointHost
        var path = "/\(credentials.bucketName)"
        if let key { path += "/" + Self.encodePath(key) }
        comps.percentEncodedPath = path
        if !query.isEmpty {
            comps.percentEncodedQueryItems = query.map {
                URLQueryItem(name: Self.encodeComponent($0.0), value: Self.encodeComponent($0.1))
            }
        }

        var request = URLRequest(url: comps.url!)
        request.httpMethod = method
        request.timeoutInterval = 120
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return AWSV4Signer.sign(request: request, credentials: credentials, payloadHash: payloadHash)
    }

    @discardableResult
    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw Self.httpError(status: http.statusCode, body: data)
        }
        return (data, http)
    }

    private func downloadTask(_ request: URLRequest, progress: Progress?) async throws -> (URL, HTTPURLResponse) {
        let holder = TaskHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.downloadTask(with: request) { location, response, error in
                    if let error { continuation.resume(throwing: error); return }
                    guard let location, let http = response as? HTTPURLResponse else {
                        continuation.resume(throwing: ClientError.invalidResponse)
                        return
                    }
                    // The system deletes `location` when this handler returns, so move it first.
                    let kept = FileManager.default.temporaryDirectory
                        .appendingPathComponent("r2-download-\(UUID().uuidString)")
                    do {
                        try FileManager.default.moveItem(at: location, to: kept)
                        continuation.resume(returning: (kept, http))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                if let progress {
                    progress.addChild(task.progress, withPendingUnitCount: max(progress.totalUnitCount, 1))
                }
                holder.task = task
                task.resume()
            }
        } onCancel: {
            holder.task?.cancel()
        }
    }

    private func uploadTask(
        _ request: URLRequest,
        fromFile fileURL: URL? = nil,
        fromData data: Data? = nil,
        progress: Progress?,
        pendingUnits: Int64
    ) async throws -> (Data, HTTPURLResponse) {
        let holder = TaskHolder()
        let (body, http): (Data, HTTPURLResponse) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let handler: @Sendable (Data?, URLResponse?, Error?) -> Void = { body, response, error in
                    if let error { continuation.resume(throwing: error); return }
                    guard let http = response as? HTTPURLResponse else {
                        continuation.resume(throwing: ClientError.invalidResponse)
                        return
                    }
                    continuation.resume(returning: (body ?? Data(), http))
                }
                let task: URLSessionUploadTask
                if let fileURL {
                    task = session.uploadTask(with: request, fromFile: fileURL, completionHandler: handler)
                } else {
                    task = session.uploadTask(with: request, from: data ?? Data(), completionHandler: handler)
                }
                if let progress {
                    progress.addChild(task.progress, withPendingUnitCount: max(pendingUnits, 1))
                }
                holder.task = task
                task.resume()
            }
        } onCancel: {
            holder.task?.cancel()
        }
        guard (200...299).contains(http.statusCode) else {
            throw Self.httpError(status: http.statusCode, body: body)
        }
        return (body, http)
    }

    // MARK: - Helpers

    private static let unreserved: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()

    static func encodeComponent(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: unreserved) ?? string
    }

    static func encodePath(_ key: String) -> String {
        key.components(separatedBy: "/").map(encodeComponent).joined(separator: "/")
    }

    static func normalizeETag(_ etag: String) -> String {
        etag.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
    }

    private static func xmlEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    /// Pass `knownSize` for upload responses, whose Content-Length describes the (empty) response body.
    private static func info(from response: HTTPURLResponse, knownSize: Int64? = nil) -> ObjectInfo {
        let size = knownSize ?? response.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) } ?? 0
        let etag = response.value(forHTTPHeaderField: "ETag").map(normalizeETag) ?? ""
        let modified = response.value(forHTTPHeaderField: "Last-Modified").flatMap { httpDateFormatter.date(from: $0) }
            ?? response.value(forHTTPHeaderField: "Date").flatMap { httpDateFormatter.date(from: $0) }
        return ObjectInfo(size: size, etag: etag, lastModified: modified)
    }

    private static func httpError(status: Int, body: Data) -> ClientError {
        let code = XMLValueParser.firstValue(of: "Code", in: body)
        let message = XMLValueParser.firstValue(of: "Message", in: body)
            ?? String(data: body, encoding: .utf8) ?? ""
        return .http(status: status, code: code, message: message)
    }
}

/// Lets a cancellation handler reach a URLSession task created inside a continuation.
private final class TaskHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var _task: URLSessionTask?
    var task: URLSessionTask? {
        get { lock.withLock { _task } }
        set { lock.withLock { _task = newValue } }
    }
}

// MARK: - XML

/// Parses a ListObjectsV2 response, including ETags.
private final class ListParser: NSObject, XMLParserDelegate {
    struct Page {
        var listing = R2Client.Listing()
        var isTruncated = false
        var nextToken: String?
    }

    private var page = Page()
    private var text = ""
    private var inContents = false
    private var inPrefixes = false
    private var key: String?
    private var size: Int64 = 0
    private var etag = ""
    private var modified: Date?

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let iso8601Plain = ISO8601DateFormatter()

    static func parse(_ data: Data) throws -> Page {
        let delegate = ListParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw R2Client.ClientError.invalidResponse }
        return delegate.page
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        text = ""
        switch elementName {
        case "Contents":
            inContents = true
            key = nil; size = 0; etag = ""; modified = nil
        case "CommonPrefixes":
            inPrefixes = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "Contents":
            if let key {
                page.listing.objects.append(R2Client.Object(key: key, size: size, etag: etag, lastModified: modified))
            }
            inContents = false
        case "CommonPrefixes":
            inPrefixes = false
        case "Key" where inContents:
            key = text
        case "Size" where inContents:
            size = Int64(value) ?? 0
        case "ETag" where inContents:
            etag = R2Client.normalizeETag(value)
        case "LastModified" where inContents:
            modified = Self.iso8601.date(from: value) ?? Self.iso8601Plain.date(from: value)
        case "Prefix" where inPrefixes:
            if !text.isEmpty { page.listing.prefixes.append(text) }
        case "IsTruncated":
            page.isTruncated = value.lowercased() == "true"
        case "NextContinuationToken":
            page.nextToken = value
        default:
            break
        }
        text = ""
    }
}

/// Pulls the first value of a named element out of a small XML document.
private final class XMLValueParser: NSObject, XMLParserDelegate {
    private let target: String
    private var capturing = false
    private var text = ""
    private var result: String?

    private init(target: String) { self.target = target }

    static func firstValue(of element: String, in data: Data) -> String? {
        let delegate = XMLValueParser(target: element)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.result
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        if elementName == target && result == nil {
            capturing = true
            text = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        if capturing && elementName == target {
            result = text.trimmingCharacters(in: .whitespacesAndNewlines)
            capturing = false
            parser.abortParsing()
        }
    }
}
