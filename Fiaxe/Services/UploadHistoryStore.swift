import Foundation
import SwiftUI

/// Persists upload history to UserDefaults as a JSON-encoded array
@Observable
final class UploadHistoryStore {
    private static let storageKey = "fiaxe.uploadHistory"
    private var isRestoring = false

    var items: [UploadItem] = [] {
        didSet {
            guard !isRestoring else { return }
            save()
        }
    }

    init() {
        load()
    }

    func add(_ item: UploadItem) {
        items.insert(item, at: 0)  // newest first
    }

    func remove(at offsets: IndexSet) {
        items.remove(atOffsets: offsets)
    }

    func remove(_ item: UploadItem) {
        items.removeAll { $0.id == item.id }
    }

    func clearAll() {
        items.removeAll()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([UploadItem].self, from: data) else { return }
        isRestoring = true
        items = decoded
        isRestoring = false
    }
}
