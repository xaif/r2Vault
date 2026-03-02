import Foundation
import CryptoKit

/// AWS Signature Version 4 signer for S3-compatible APIs (Cloudflare R2).
/// All methods are nonisolated to allow calling from any actor context.
nonisolated enum AWSV4Signer {

    /// Signs a URLRequest with AWS Signature V4 and returns the signed request.
    /// - Parameters:
    ///   - request: Request with url, httpMethod, and headers already set
    ///   - credentials: R2 credentials (account ID, access key, secret key)
    ///   - payloadHash: SHA-256 hex digest of the body, or "UNSIGNED-PAYLOAD" for streaming uploads
    ///   - date: Signing date (defaults to now)
    static func sign(
        request: URLRequest,
        credentials: R2Credentials,
        payloadHash: String = "UNSIGNED-PAYLOAD",
        date: Date = Date()
    ) -> URLRequest {
        var request = request
        let region = "auto"
        let service = "s3"

        let amzDate = amzDateString(from: date)
        let shortDate = shortDateString(from: date)
        let credentialScope = "\(shortDate)/\(region)/\(service)/aws4_request"

        // Add required headers before building canonical request
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        if let host = request.url?.host {
            request.setValue(host, forHTTPHeaderField: "Host")
        }

        // Build canonical request
        let httpMethod = request.httpMethod ?? "PUT"
        let canonicalURI = canonicalPath(from: request.url)
        let canonicalQS = canonicalQueryString(from: request.url)

        let allHeaders = request.allHTTPHeaderFields ?? [:]
        let sortedLowercasedKeys = allHeaders.keys.map { $0.lowercased() }.sorted()
        let signedHeaders = sortedLowercasedKeys.joined(separator: ";")
        let canonicalHeaders = sortedLowercasedKeys
            .map { key -> String in
                let value = allHeaders.first { $0.key.lowercased() == key }?.value ?? ""
                return "\(key):\(value.trimmingCharacters(in: .whitespaces))"
            }
            .joined(separator: "\n")

        let canonicalRequest = [
            httpMethod,
            canonicalURI,
            canonicalQS,
            canonicalHeaders + "\n",
            signedHeaders,
            payloadHash
        ].joined(separator: "\n")

        // String to sign
        let canonicalRequestHash = sha256Hex(canonicalRequest)
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            credentialScope,
            canonicalRequestHash
        ].joined(separator: "\n")

        // Derive signing key and compute signature
        let signingKey = deriveSigningKey(
            secret: credentials.secretAccessKey,
            date: shortDate,
            region: region,
            service: service
        )
        let signature = hmacHex(key: signingKey, data: Data(stringToSign.utf8))

        let authorization = "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyId)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")

        return request
    }

    // MARK: - Helpers

    private static func amzDateString(from date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: date)
    }

    private static func shortDateString(from date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: date)
    }

    private static func canonicalPath(from url: URL?) -> String {
        guard let url else { return "/" }
        // Extract the raw percent-encoded path from the URL string so we preserve
        // trailing slashes (url.path strips them) and don't double-encode.
        let rawPath: String
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           !comps.percentEncodedPath.isEmpty {
            rawPath = comps.percentEncodedPath
        } else {
            rawPath = url.path
        }
        guard !rawPath.isEmpty else { return "/" }
        // Decode each segment then re-encode with the strict AWS URI-encode set,
        // preserving slashes as separators and trailing slash if present.
        let hasTrailing = rawPath.hasSuffix("/")
        let segments = rawPath.components(separatedBy: "/")
        let encoded = segments
            .map { seg -> String in
                // Decode any existing percent-encoding then strict re-encode
                let decoded = seg.removingPercentEncoding ?? seg
                return uriEncode(decoded)
            }
            .joined(separator: "/")
        // Restore trailing slash if it was present
        return hasTrailing && !encoded.hasSuffix("/") ? encoded + "/" : encoded
    }

    private static func canonicalQueryString(from url: URL?) -> String {
        guard let url,
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems, !items.isEmpty else { return "" }
        return items
            .sorted { $0.name < $1.name }
            .map { "\(uriEncode($0.name))=\(uriEncode($0.value ?? ""))" }
            .joined(separator: "&")
    }

    private static func uriEncode(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    /// Generates a presigned GET URL valid for `expiresIn` seconds.
    /// The resulting URL can be fetched without any auth headers.
    static func presignedURL(
        for key: String,
        credentials: R2Credentials,
        expiresIn: Int = 3600,
        date: Date = Date()
    ) -> URL? {
        let region = "auto"
        let service = "s3"
        let amzDate = amzDateString(from: date)
        let shortDate = shortDateString(from: date)
        let credentialScope = "\(shortDate)/\(region)/\(service)/aws4_request"

        // Build the base URL using URLComponents to preserve slashes
        let encodedKey = key
            .components(separatedBy: "/")
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
            .joined(separator: "/")
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "\(credentials.accountId).r2.cloudflarestorage.com"
        comps.percentEncodedPath = "/\(credentials.bucketName)/\(encodedKey)"

        // Required presign query parameters (must be sorted for canonical QS)
        comps.queryItems = [
            URLQueryItem(name: "X-Amz-Algorithm",     value: "AWS4-HMAC-SHA256"),
            URLQueryItem(name: "X-Amz-Credential",    value: "\(credentials.accessKeyId)/\(credentialScope)"),
            URLQueryItem(name: "X-Amz-Date",          value: amzDate),
            URLQueryItem(name: "X-Amz-Expires",       value: "\(expiresIn)"),
            URLQueryItem(name: "X-Amz-SignedHeaders", value: "host"),
        ]

        guard let url = comps.url else { return nil }

        // Canonical request with UNSIGNED-PAYLOAD (standard for presigned URLs)
        let canonicalURI = canonicalPath(from: url)
        let canonicalQS  = canonicalQueryString(from: url)
        let host = "\(credentials.accountId).r2.cloudflarestorage.com"
        let canonicalHeaders = "host:\(host)\n"
        let signedHeaders    = "host"
        let payloadHash      = "UNSIGNED-PAYLOAD"

        let canonicalRequest = [
            "GET", canonicalURI, canonicalQS,
            canonicalHeaders, signedHeaders, payloadHash
        ].joined(separator: "\n")

        let stringToSign = [
            "AWS4-HMAC-SHA256", amzDate, credentialScope, sha256Hex(canonicalRequest)
        ].joined(separator: "\n")

        let signingKey = deriveSigningKey(secret: credentials.secretAccessKey, date: shortDate, region: region, service: service)
        let signature  = hmacHex(key: signingKey, data: Data(stringToSign.utf8))

        comps.queryItems?.append(URLQueryItem(name: "X-Amz-Signature", value: signature))
        return comps.url
    }

    static func sha256Hex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func deriveSigningKey(secret: String, date: String, region: String, service: String) -> SymmetricKey {
        let kSecret = SymmetricKey(data: Data(("AWS4" + secret).utf8))
        let kDate = hmac(key: kSecret, data: Data(date.utf8))
        let kRegion = hmac(key: kDate, data: Data(region.utf8))
        let kService = hmac(key: kRegion, data: Data(service.utf8))
        return hmac(key: kService, data: Data("aws4_request".utf8))
    }

    private static func hmac(key: SymmetricKey, data: Data) -> SymmetricKey {
        SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: data, using: key)))
    }

    private static func hmacHex(key: SymmetricKey, data: Data) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
            .map { String(format: "%02x", $0) }.joined()
    }
}
