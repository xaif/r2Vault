import Foundation

/// Stores R2 credentials in UserDefaults.
/// For a personal single-user tool this is sufficient;
/// the secret key is stored in plain text on your own machine.
enum KeychainService {
    private static let storageKey = "fiaxe.r2credentials"

    static func saveAll(_ credentials: [R2Credentials]) throws {
        let data = try JSONEncoder().encode(credentials)
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    static func loadAll() throws -> [R2Credentials] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [] }
        if let decoded = try? JSONDecoder().decode([R2Credentials].self, from: data) {
            return decoded
        }
        if let single = try? JSONDecoder().decode(R2Credentials.self, from: data) {
            return [single]
        }
        return []
    }

    static func deleteAll() throws {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}
