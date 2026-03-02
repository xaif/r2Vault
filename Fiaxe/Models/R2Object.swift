import Foundation

/// Represents a file or folder entry in the R2 bucket
struct R2Object: Identifiable, Sendable {
    let id = UUID()
    let key: String
    let size: Int64
    let lastModified: Date?
    let isFolder: Bool

    /// The display name — last path component, strips trailing slash for folders
    var name: String {
        let stripped = key.hasSuffix("/") ? String(key.dropLast()) : key
        return stripped.components(separatedBy: "/").last ?? stripped
    }

    /// Human-readable file size; folders show "--"
    var formattedSize: String {
        if isFolder { return "--" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    /// Human-readable last-modified date
    var formattedDate: String {
        guard let date = lastModified else { return "--" }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }
}
