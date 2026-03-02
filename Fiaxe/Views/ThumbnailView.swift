import SwiftUI

/// Displays a cached thumbnail for an R2 file, falling back to an SF Symbol
/// while loading or for unsupported file types.
struct ThumbnailView: View {
    let object: R2Object
    let credentials: R2Credentials
    let size: CGFloat

    @State private var thumbnail: NSImage? = nil
    @State private var isLoading = false

    private var ext: String {
        (object.name as NSString).pathExtension.lowercased()
    }

    private var supportsPreview: Bool {
        let imageExts = ["jpg","jpeg","png","gif","webp","heic","heif","bmp","tiff"]
        let videoExts = ["mp4","mov","avi","mkv","webm","m4v"]
        return imageExts.contains(ext) || videoExts.contains(ext)
    }

    var body: some View {
        Group {
            if let img = thumbnail {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                fallbackIcon
                    .overlay {
                        if isLoading && supportsPreview {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.black.opacity(0.25))
                            ProgressView()
                                .scaleEffect(0.6)
                                .tint(.white)
                        }
                    }
            }
        }
        .frame(width: size, height: size)
        .task(id: object.key) {
            guard supportsPreview, thumbnail == nil else { return }
            isLoading = true
            thumbnail = await ThumbnailCache.shared.thumbnail(for: object.key, credentials: credentials)
            isLoading = false
        }
    }

    private var fallbackIcon: some View {
        Image(systemName: iconName)
            .font(.system(size: size * 0.55, weight: .light))
            .foregroundStyle(iconColor)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(NSColor.quaternaryLabelColor).opacity(0.08))
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var iconName: String {
        if object.isFolder { return "folder.fill" }
        switch ext {
        case "jpg","jpeg","png","gif","webp","heic","heif","bmp","tiff","svg": return "photo"
        case "mp4","mov","avi","mkv","webm","m4v": return "film"
        case "mp3","m4a","wav","aac","flac","ogg": return "music.note"
        case "pdf": return "doc.richtext"
        case "zip","tar","gz","bz2","7z","rar": return "archivebox"
        case "swift","py","js","ts","json","xml","html","css","sh","rb","go","rs":
            return "chevron.left.forwardslash.chevron.right"
        case "doc","docx": return "doc.text"
        case "xls","xlsx": return "tablecells"
        case "ppt","pptx": return "rectangle.on.rectangle"
        default: return "doc"
        }
    }

    private var iconColor: Color {
        if object.isFolder { return .accentColor }
        switch ext {
        case "jpg","jpeg","png","gif","webp","heic","heif","bmp","tiff","svg": return .purple
        case "mp4","mov","avi","mkv","webm","m4v": return .pink
        case "mp3","m4a","wav","aac","flac","ogg": return .orange
        case "pdf": return .red
        case "zip","tar","gz","bz2","7z","rar": return .brown
        case "swift","py","js","ts","json","xml","html","css","sh","rb","go","rs": return .mint
        default: return .secondary
        }
    }
}
