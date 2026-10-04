import Foundation

/// Where a bucket's data is legally kept. Buckets created with a jurisdiction are only
/// reachable through that jurisdiction's endpoint.
enum R2Jurisdiction: String, CaseIterable, Codable, Sendable, Identifiable {
    case auto
    case eu
    case fedramp
    case us

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: "None (default)"
        case .eu: "European Union (EU)"
        case .fedramp: "FedRAMP"
        case .us: "United States (US)"
        }
    }

    var endpointSuffix: String {
        switch self {
        case .auto: "r2.cloudflarestorage.com"
        default: "\(rawValue).r2.cloudflarestorage.com"
        }
    }

    /// The jurisdiction in an S3 endpoint like `https://<account>.eu.r2.cloudflarestorage.com`.
    init?(endpoint: String) {
        let withScheme = endpoint.contains("://") ? endpoint : "https://\(endpoint)"
        guard let host = URLComponents(string: withScheme)?.host?.lowercased(),
              host.hasSuffix(".r2.cloudflarestorage.com") else { return nil }
        let labels = host.split(separator: ".")
        self = labels.count == 5 ? (Self(rawValue: String(labels[1])) ?? .auto) : .auto
    }
}

struct R2Credentials: Sendable, Codable, Equatable, Identifiable {
    var id: UUID
    var accountId: String
    var accessKeyId: String
    var secretAccessKey: String
    var bucketName: String
    var customDomain: String?
    var jurisdiction: R2Jurisdiction

    var isEmpty: Bool {
        accountId.isEmpty || accessKeyId.isEmpty || secretAccessKey.isEmpty || bucketName.isEmpty
    }

    init(
        id: UUID = UUID(),
        accountId: String,
        accessKeyId: String,
        secretAccessKey: String,
        bucketName: String,
        customDomain: String? = nil,
        jurisdiction: R2Jurisdiction = .auto
    ) {
        self.id = id
        self.accountId = accountId
        self.accessKeyId = accessKeyId
        self.secretAccessKey = secretAccessKey
        self.bucketName = bucketName
        self.customDomain = customDomain
        self.jurisdiction = jurisdiction
    }

    private enum CodingKeys: String, CodingKey {
        case id, accountId, accessKeyId, secretAccessKey, bucketName, customDomain, jurisdiction
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        accountId = try container.decode(String.self, forKey: .accountId)
        accessKeyId = try container.decode(String.self, forKey: .accessKeyId)
        secretAccessKey = try container.decode(String.self, forKey: .secretAccessKey)
        bucketName = try container.decode(String.self, forKey: .bucketName)
        customDomain = try container.decodeIfPresent(String.self, forKey: .customDomain)
        // Saved before jurisdictions existed, or by a newer version with one this build doesn't know.
        jurisdiction = (try? container.decodeIfPresent(R2Jurisdiction.self, forKey: .jurisdiction)) ?? .auto
    }

    /// Host of the S3-compatible endpoint for this account and jurisdiction
    var endpointHost: String {
        "\(accountId).\(jurisdiction.endpointSuffix)"
    }

    /// S3-compatible endpoint for this R2 account
    var endpoint: URL {
        URL(string: "https://\(endpointHost)")!
    }

    static func normalizedCustomDomain(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.query == nil,
              components.fragment == nil else {
            return nil
        }

        components.scheme = "https"
        components.user = nil
        components.password = nil

        if components.percentEncodedPath == "/" {
            components.percentEncodedPath = ""
        }

        return components.url?.absoluteString
    }

    /// Constructs the public URL for an uploaded object key
    func publicURL(forKey key: String) -> URL {
        if let customDomain = Self.normalizedCustomDomain(customDomain),
           let base = URL(string: customDomain) {
            return base.appendingPathComponent(key)
        }
        return endpoint
            .appendingPathComponent(bucketName)
            .appendingPathComponent(key)
    }
}
