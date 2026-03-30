import Foundation

enum R2Jurisdiction: String, CaseIterable, Codable, Sendable, Identifiable {
    case auto
    case eu

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto:
            return "Global (Auto)"
        case .eu:
            return "European Union (EU)"
        }
    }

    var endpointSuffix: String {
        switch self {
        case .auto:
            return "r2.cloudflarestorage.com"
        case .eu:
            return "eu.r2.cloudflarestorage.com"
        }
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
        case id
        case accountId
        case accessKeyId
        case secretAccessKey
        case bucketName
        case customDomain
        case jurisdiction
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        accountId = try container.decode(String.self, forKey: .accountId)
        accessKeyId = try container.decode(String.self, forKey: .accessKeyId)
        secretAccessKey = try container.decode(String.self, forKey: .secretAccessKey)
        bucketName = try container.decode(String.self, forKey: .bucketName)
        customDomain = try container.decodeIfPresent(String.self, forKey: .customDomain)
        jurisdiction = (try? container.decode(R2Jurisdiction.self, forKey: .jurisdiction)) ?? .auto
    }

    /// S3-compatible endpoint for this R2 account
    var endpointHost: String {
        "\(accountId).\(jurisdiction.endpointSuffix)"
    }

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
