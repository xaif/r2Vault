import FileProvider
import UniformTypeIdentifiers

/// An item as reported to the system, built from an `ItemRecord`.
final class FileProviderItem: NSObject, NSFileProviderItem, @unchecked Sendable {
    let record: ItemRecord

    init(_ record: ItemRecord) {
        self.record = record
    }

    var itemIdentifier: NSFileProviderItemIdentifier {
        NSFileProviderItemIdentifier(record.id)
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        NSFileProviderItemIdentifier(record.parentID)
    }

    /// The system requires every item, including the containers, to have a filename.
    /// (Finder shows the domain's display name for the root, not this.)
    var filename: String {
        switch record.id {
        case ItemDatabase.rootID: return "R2Vault"
        case ItemDatabase.trashID: return "Trash"
        default: return record.name
        }
    }

    var contentType: UTType {
        let ext = (record.name as NSString).pathExtension
        if record.isFolder {
            if !ext.isEmpty, let package = UTType(filenameExtension: ext, conformingTo: .package),
               !package.isDynamic, package.conforms(to: .package) {
                return package
            }
            return .folder
        }
        return UTType(filenameExtension: ext) ?? .data
    }

    var capabilities: NSFileProviderItemCapabilities {
        if record.id == ItemDatabase.rootID || record.id == ItemDatabase.trashID {
            return [.allowsReading, .allowsWriting, .allowsAddingSubItems, .allowsContentEnumerating]
        }
        var capabilities: NSFileProviderItemCapabilities = [
            .allowsReading, .allowsRenaming, .allowsReparenting, .allowsTrashing, .allowsDeleting,
        ]
        if record.isFolder {
            capabilities.formUnion([.allowsAddingSubItems, .allowsContentEnumerating])
        } else {
            capabilities.insert(.allowsWriting)
        }
        return capabilities
    }

    /// The drive downloads on demand, and downloads can be removed: by Finder's "Remove Download",
    /// or by the system when space runs low. Without a content policy, downloads are permanent.
    /// Items the user chose to keep downloaded (and, through inheritance, everything inside such
    /// a folder) are fetched eagerly and never evicted.
    var contentPolicy: NSFileProviderContentPolicy {
        if record.id == ItemDatabase.rootID || record.id == ItemDatabase.trashID {
            return .downloadLazily
        }
        return record.keepDownloaded && !isInTrash ? .downloadEagerlyAndKeepDownloaded : .inherited
    }

    /// Read by the Keep Downloaded actions' activation rules in Info.plist. Containers and
    /// trashed items get no actions.
    var userInfo: [AnyHashable: Any]? {
        guard record.id != ItemDatabase.rootID, record.id != ItemDatabase.trashID, !isInTrash else { return nil }
        return ["keepDownloaded": record.keepDownloaded]
    }

    private var isInTrash: Bool {
        record.key.hasPrefix(FinderDrive.trashPrefix)
    }

    /// macOS 27: keep the whole folder tree listed in the background, so every folder opens
    /// instantly. Only listings are fetched eagerly; file contents still download on demand.
    /// The Trash stays lazy.
    @available(macOS 27.0, *)
    var namespacePolicy: NSFileProviderNamespacePolicy {
        guard record.isFolder else { return .inherited }
        if record.id == ItemDatabase.trashID || isInTrash {
            return .materializeLazily
        }
        return .materializeEagerly
    }

    var documentSize: NSNumber? {
        record.isFolder ? nil : NSNumber(value: record.size)
    }

    var contentModificationDate: Date? {
        record.modified
    }

    var creationDate: Date? {
        record.modified
    }

    var itemVersion: NSFileProviderItemVersion {
        // Content changes whenever the ETag does; metadata whenever the record is rewritten.
        let content = Data((record.isFolder ? "folder" : record.etag).utf8)
        let metadata = Data("\(record.seq)".utf8)
        return NSFileProviderItemVersion(contentVersion: content, metadataVersion: metadata)
    }

    static func rootItem() -> FileProviderItem {
        FileProviderItem(ItemRecord(id: ItemDatabase.rootID, key: "", parentID: ItemDatabase.rootID, name: "",
                                    isFolder: true, size: 0, etag: "", modified: nil, seq: 0))
    }
}
