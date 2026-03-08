import Foundation

struct R2Credentials: Sendable, Codable, Equatable, Identifiable {
    var id: UUID
    var accountId: String
    var accessKeyId: String
    var secretAccessKey: String
    var bucketName: String
    var customDomain: String?

    var isEmpty: Bool {
        accountId.isEmpty || accessKeyId.isEmpty || secretAccessKey.isEmpty || bucketName.isEmpty
    }

    init(
        id: UUID = UUID(),
        accountId: String,
        accessKeyId: String,
        secretAccessKey: String,
        bucketName: String,
        customDomain: String? = nil
    ) {
        self.id = id
        self.accountId = accountId
        self.accessKeyId = accessKeyId
        self.secretAccessKey = secretAccessKey
        self.bucketName = bucketName
        self.customDomain = customDomain
    }

    /// S3-compatible endpoint for this R2 account
    var endpoint: URL {
        URL(string: "https://\(accountId).r2.cloudflarestorage.com")!
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
