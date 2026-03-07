import Foundation

/// Result from a ListObjectsV2 call
struct ListResult: Sendable {
    var objects: [R2Object]        // files (Contents)
    var folders: [R2Object]        // virtual folders (CommonPrefixes)
    var isTruncated: Bool
    var nextContinuationToken: String?
}

/// Provides S3-compatible ListObjectsV2, create-folder, and delete operations against Cloudflare R2.
nonisolated enum R2BrowseService {

    // MARK: - List Objects

    /// Lists the objects and virtual folders at `prefix` (one level deep).
    static func listObjects(credentials: R2Credentials, prefix: String = "") async throws -> ListResult {
        var allObjects: [R2Object] = []
        var allFolders: [R2Object] = []
        var continuationToken: String? = nil

        repeat {
            let page = try await listPage(
                credentials: credentials,
                prefix: prefix,
                continuationToken: continuationToken
            )
            allObjects.append(contentsOf: page.objects)
            allFolders.append(contentsOf: page.folders)
            continuationToken = page.isTruncated ? page.nextContinuationToken : nil
        } while continuationToken != nil

        return ListResult(
            objects: allObjects,
            folders: allFolders,
            isTruncated: false,
            nextContinuationToken: nil
        )
    }

    private static func listPage(
        credentials: R2Credentials,
        prefix: String,
        continuationToken: String?
    ) async throws -> ListResult {
        let baseURL = credentials.endpoint
            .appendingPathComponent(credentials.bucketName)

        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "list-type", value: "2"),
            URLQueryItem(name: "delimiter", value: "/"),
        ]
        if !prefix.isEmpty {
            queryItems.append(URLQueryItem(name: "prefix", value: prefix))
        }
        if let token = continuationToken {
            queryItems.append(URLQueryItem(name: "continuation-token", value: token))
        }
        comps.queryItems = queryItems

        guard let url = comps.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let emptyHash = AWSV4Signer.sha256Hex("")
        let signed = AWSV4Signer.sign(request: request, credentials: credentials, payloadHash: emptyHash)

        let (data, response) = try await URLSession.shared.data(for: signed)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw R2BrowseError.httpError(httpResponse.statusCode, body)
        }

        let parser = ListBucketResultParser()
        return try parser.parse(data: data)
    }

    // MARK: - Create Folder

    /// Creates a virtual folder by putting a zero-byte object with a trailing slash.
    static func createFolder(credentials: R2Credentials, folderKey: String) async throws {
        let key = folderKey.hasSuffix("/") ? folderKey : folderKey + "/"
        guard let url = objectURL(credentials: credentials, key: key) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("0", forHTTPHeaderField: "Content-Length")
        request.setValue("application/x-directory", forHTTPHeaderField: "Content-Type")

        let emptyHash = AWSV4Signer.sha256Hex("")
        let signed = AWSV4Signer.sign(request: request, credentials: credentials, payloadHash: emptyHash)

        let (data, response) = try await URLSession.shared.data(for: signed)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw R2BrowseError.httpError(statusCode, body)
        }
    }

    // MARK: - Delete Object

    /// Lists every object key that starts with `prefix` (no delimiter — fully recursive).
    static func listAllKeys(credentials: R2Credentials, prefix: String) async throws -> [String] {
        var allKeys: [String] = []
        var continuationToken: String? = nil

        repeat {
            let baseURL = credentials.endpoint
                .appendingPathComponent(credentials.bucketName)

            var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "list-type", value: "2"),
                URLQueryItem(name: "prefix", value: prefix),
            ]
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

            // Parse keys + truncation from the flat (no-delimiter) list
            let parser = FlatListParser()
            let result = try parser.parse(data: data)
            allKeys.append(contentsOf: result.keys)
            continuationToken = result.isTruncated ? result.nextContinuationToken : nil
        } while continuationToken != nil

        return allKeys
    }

    // MARK: - URL Builder

    /// Builds a correctly percent-encoded URL for a bucket object key, preserving trailing slashes.
    private static func objectURL(credentials: R2Credentials, key: String) -> URL? {
        // Encode each path segment individually, preserving slashes and trailing slash
        let encodedKey = key
            .components(separatedBy: "/")
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
            .joined(separator: "/")
        let rawPath = "/\(credentials.bucketName)/\(encodedKey)"
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "\(credentials.accountId).r2.cloudflarestorage.com"
        comps.percentEncodedPath = rawPath
        return comps.url
    }

    /// Deletes an object by key.
    static func deleteObject(credentials: R2Credentials, key: String) async throws {
        guard let url = objectURL(credentials: credentials, key: key) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"

        let emptyHash = AWSV4Signer.sha256Hex("")
        let signed = AWSV4Signer.sign(request: request, credentials: credentials, payloadHash: emptyHash)

        let (data, response) = try await URLSession.shared.data(for: signed)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 204 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw R2BrowseError.httpError(statusCode, body)
        }
    }
}

// MARK: - Errors

enum R2BrowseError: LocalizedError {
    case httpError(Int, String)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .httpError(let code, let body):
            return "HTTP \(code): \(body)"
        case .parseError(let msg):
            return "XML parse error: \(msg)"
        }
    }
}

// MARK: - XML Parser

private final class ListBucketResultParser: NSObject, XMLParserDelegate, @unchecked Sendable {
    private var objects: [R2Object] = []
    private var folders: [R2Object] = []
    private var isTruncated = false
    private var nextContinuationToken: String?

    // Current element tracking
    private var currentElement = ""
    private var currentText = ""

    // Current <Contents> object being built
    private var inContents = false
    private var currentKey: String?
    private var currentSize: Int64 = 0
    private var currentLastModified: Date?

    // Current <CommonPrefixes> folder
    private var inCommonPrefixes = false

    private let iso8601: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt
    }()

    func parse(data: Data) throws -> ListResult {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else {
            throw R2BrowseError.parseError(parser.parserError?.localizedDescription ?? "Unknown parse error")
        }
        return ListResult(
            objects: objects,
            folders: folders,
            isTruncated: isTruncated,
            nextContinuationToken: nextContinuationToken
        )
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        currentText = ""
        if elementName == "Contents" { inContents = true }
        if elementName == "CommonPrefixes" { inCommonPrefixes = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch elementName {
        case "Contents":
            if let key = currentKey {
                let obj = R2Object(key: key, size: currentSize, lastModified: currentLastModified, isFolder: false)
                objects.append(obj)
            }
            inContents = false
            currentKey = nil
            currentSize = 0
            currentLastModified = nil

        case "CommonPrefixes":
            inCommonPrefixes = false

        case "Key":
            if inContents {
                currentKey = text
            }

        case "Size":
            if inContents {
                currentSize = Int64(text) ?? 0
            }

        case "LastModified":
            if inContents {
                currentLastModified = iso8601.date(from: text)
                    ?? ISO8601DateFormatter().date(from: text)
            }

        case "Prefix":
            // Inside <CommonPrefixes>, this is a folder key
            if inCommonPrefixes && !text.isEmpty {
                let folder = R2Object(key: text, size: 0, lastModified: nil, isFolder: true)
                folders.append(folder)
            }

        case "IsTruncated":
            isTruncated = text.lowercased() == "true"

        case "NextContinuationToken":
            nextContinuationToken = text

        default:
            break
        }

        currentElement = ""
        currentText = ""
    }
}

// MARK: - Full List Parser (no delimiter — returns R2Objects with size/date)

struct FullListParseResult: Sendable {
    var objects: [R2Object]
    var isTruncated: Bool
    var nextContinuationToken: String?
}

final class FullListParser: NSObject, XMLParserDelegate, @unchecked Sendable {
    private var objects: [R2Object] = []
    private var isTruncated = false
    private var nextContinuationToken: String?
    private var currentElement = ""
    private var currentText = ""
    private var inContents = false
    private var currentKey: String?
    private var currentSize: Int64 = 0
    private var currentLastModified: Date?

    private let iso8601: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt
    }()

    func parse(data: Data) throws -> FullListParseResult {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else {
            throw R2BrowseError.parseError(parser.parserError?.localizedDescription ?? "Parse error")
        }
        return FullListParseResult(objects: objects, isTruncated: isTruncated, nextContinuationToken: nextContinuationToken)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        currentElement = elementName
        currentText = ""
        if elementName == "Contents" { inContents = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "Contents":
            if let key = currentKey {
                objects.append(R2Object(key: key, size: currentSize, lastModified: currentLastModified, isFolder: false))
            }
            inContents = false
            currentKey = nil
            currentSize = 0
            currentLastModified = nil
        case "Key":
            if inContents { currentKey = text }
        case "Size":
            if inContents { currentSize = Int64(text) ?? 0 }
        case "LastModified":
            if inContents {
                currentLastModified = iso8601.date(from: text) ?? ISO8601DateFormatter().date(from: text)
            }
        case "IsTruncated":
            isTruncated = text.lowercased() == "true"
        case "NextContinuationToken":
            nextContinuationToken = text
        default:
            break
        }
        currentElement = ""
        currentText = ""
    }
}

// MARK: - Flat List Parser (no delimiter — for recursive enumeration)

private struct FlatListResult {
    var keys: [String]
    var isTruncated: Bool
    var nextContinuationToken: String?
}

private final class FlatListParser: NSObject, XMLParserDelegate, @unchecked Sendable {
    private var keys: [String] = []
    private var isTruncated = false
    private var nextContinuationToken: String?
    private var currentElement = ""
    private var currentText = ""
    private var inContents = false

    func parse(data: Data) throws -> FlatListResult {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else {
            throw R2BrowseError.parseError(parser.parserError?.localizedDescription ?? "Parse error")
        }
        return FlatListResult(keys: keys, isTruncated: isTruncated, nextContinuationToken: nextContinuationToken)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        currentElement = elementName
        currentText = ""
        if elementName == "Contents" { inContents = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "Contents":
            inContents = false
        case "Key":
            if inContents { keys.append(text) }
        case "IsTruncated":
            isTruncated = text.lowercased() == "true"
        case "NextContinuationToken":
            nextContinuationToken = text
        default:
            break
        }
        currentElement = ""
        currentText = ""
    }
}
