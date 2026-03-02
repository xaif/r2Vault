import Foundation
import SwiftUI

/// Persists upload history to UserDefaults as a JSON-encoded array
@Observable
final class UploadHistoryStore {
    private static let storageKey = "fiaxe.uploadHistory"

    var items: [UploadItem] = []

    init() {
        load()
    }

    func add(_ item: UploadItem) {
        items.insert(item, at: 0)  // newest first
        save()
    }

    func remove(at offsets: IndexSet) {
        items.remove(atOffsets: offsets)
        save()
    }

    func clearAll() {
        items.removeAll()
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([UploadItem].self, from: data) else { return }
        items = decoded
    }
}
