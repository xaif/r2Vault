import Foundation
import Security

/// Stores R2 credentials securely in the system Keychain.
enum KeychainService {
    private static let service = "fiaxe.r2credentials"
    private static let account = "r2credentials"

    // MARK: - Public API

    static func saveAll(_ credentials: [R2Credentials]) throws {
        let data = try JSONEncoder().encode(credentials)
        try setKeychainData(data)
    }

    static func loadAll() throws -> [R2Credentials] {
        // Try loading from Keychain first
        if let data = try getKeychainData() {
            if let decoded = try? JSONDecoder().decode([R2Credentials].self, from: data) {
                return decoded
            }
            if let single = try? JSONDecoder().decode(R2Credentials.self, from: data) {
                return [single]
            }
        }

        // Migration: check if credentials exist in the old UserDefaults location
        // and migrate them to Keychain on first run after update.
        if let legacyData = UserDefaults.standard.data(forKey: "fiaxe.r2credentials") {
            var migrated: [R2Credentials] = []
            if let decoded = try? JSONDecoder().decode([R2Credentials].self, from: legacyData) {
                migrated = decoded
            } else if let single = try? JSONDecoder().decode(R2Credentials.self, from: legacyData) {
                migrated = [single]
            }
            if !migrated.isEmpty {
                try? saveAll(migrated)
                UserDefaults.standard.removeObject(forKey: "fiaxe.r2credentials")
            }
            return migrated
        }

        return []
    }

    static func deleteAll() throws {
        try deleteKeychainItem()
        // Also clean up any lingering legacy data
        UserDefaults.standard.removeObject(forKey: "fiaxe.r2credentials")
    }

    // MARK: - Keychain Helpers

    private static func setKeychainData(_ data: Data) throws {
        // Try updating first; if the item doesn't exist, add it.
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [
            kSecValueData as String:            data,
            kSecAttrAccessible as String:       kSecAttrAccessibleWhenUnlocked,
        ]

        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)

        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }

        guard status == errSecSuccess else {
            throw KeychainError.unhandledError(status: status)
        }
    }

    private static func getKeychainData() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.unhandledError(status: status)
        }
        return result as? Data
    }

    private static func deleteKeychainItem() throws {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledError(status: status)
        }
    }
}

// MARK: - Errors

enum KeychainError: LocalizedError {
    case unhandledError(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .unhandledError(let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return "Keychain error: \(message)"
            }
            return "Keychain error: \(status)"
        }
    }
}
