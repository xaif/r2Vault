import Foundation

/// Aggregated statistics for a single R2 bucket
struct BucketStats: Sendable {
    var totalFiles: Int = 0
    var totalFolders: Int = 0
    var totalSize: Int64 = 0
    var filesByType: [FileCategory: CategoryStats] = [:]
    var largestFiles: [FileInfo] = []
    var recentFiles: [FileInfo] = []
    var lastScanned: Date? = nil

    var formattedTotalSize: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }

    struct FileInfo: Sendable, Identifiable {
        let id = UUID()
        let key: String
        let size: Int64
        let lastModified: Date?

        var name: String {
            let stripped = key.hasSuffix("/") ? String(key.dropLast()) : key
            return stripped.components(separatedBy: "/").last ?? stripped
        }

        var formattedSize: String {
            ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        }
    }

    struct CategoryStats: Sendable {
        var count: Int = 0
        var totalSize: Int64 = 0

        var formattedSize: String {
            ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
        }
    }

    enum FileCategory: String, CaseIterable, Sendable {
        case images = "Images"
        case videos = "Videos"
        case audio = "Audio"
        case documents = "Documents"
        case archives = "Archives"
        case code = "Code"
        case other = "Other"

        var icon: String {
            switch self {
            case .images: return "photo.fill"
            case .videos: return "video.fill"
            case .audio: return "music.note"
            case .documents: return "doc.text.fill"
            case .archives: return "archivebox.fill"
            case .code: return "chevron.left.forwardslash.chevron.right"
            case .other: return "doc.fill"
            }
        }

        var color: String {
            switch self {
            case .images: return "purple"
            case .videos: return "pink"
            case .audio: return "orange"
            case .documents: return "blue"
            case .archives: return "brown"
            case .code: return "mint"
            case .other: return "gray"
            }
        }

        static func categorize(extension ext: String) -> FileCategory {
            switch ext.lowercased() {
            case "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff", "svg", "ico":
                return .images
            case "mp4", "mov", "avi", "mkv", "webm", "m4v", "wmv", "flv":
                return .videos
            case "mp3", "m4a", "wav", "aac", "flac", "ogg", "wma":
                return .audio
            case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "csv":
                return .documents
            case "zip", "tar", "gz", "bz2", "7z", "rar", "dmg", "iso":
                return .archives
            case "swift", "py", "js", "ts", "json", "xml", "html", "css", "sh", "rb", "go", "rs",
                 "java", "kt", "c", "cpp", "h", "hpp", "yaml", "yml", "toml", "md":
                return .code
            default:
                return .other
            }
        }
    }
}
