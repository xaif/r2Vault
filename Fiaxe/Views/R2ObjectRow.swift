import SwiftUI
import AppKit

/// A single row for List view — unified files + folders, with selection support.
struct R2ObjectRow: View {
    let object: R2Object
    let credentials: R2Credentials
    let isSelected: Bool
    let onNavigate: (R2Object) -> Void
    let onCopyURL: (String) -> Void
    let onPreview: (R2Object) -> Void
    let onDownload: (URL, URL) -> Void  // (remoteURL, destinationURL)
    let onDelete: (R2Object) -> Void

    @State private var copied = false
    @State private var showDeleteConfirm = false

    var body: some View {
        HStack(spacing: 10) {
            // Icon
            Image(systemName: iconName)
                .font(.system(size: 15))
                .foregroundStyle(object.isFolder ? Color.accentColor : iconColor)
                .frame(width: 22, alignment: .center)

            // Name
            Text(object.name)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Kind badge
            Text(object.isFolder ? "Folder" : kindLabel)
                .foregroundStyle(.secondary)
                .font(.callout)
                .frame(width: 80, alignment: .trailing)

            // Size column
            Text(object.formattedSize)
                .foregroundStyle(.secondary)
                .font(.callout)
                .monospacedDigit()
                .frame(width: 72, alignment: .trailing)

            // Date column
            Text(object.formattedDate)
                .foregroundStyle(.secondary)
                .font(.callout)
                .frame(width: 140, alignment: .trailing)

            // Action buttons
            if object.isFolder {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 80)
            } else {
                HStack(spacing: 8) {
                    Button {
                        let url = credentials.publicURL(forKey: object.key)
                        onCopyURL(url.absoluteString)
                        withAnimation(.easeInOut(duration: 0.15)) { copied = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation(.easeInOut(duration: 0.2)) { copied = false }
                        }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "link")
                            .foregroundStyle(copied ? .green : .secondary)
                            .frame(width: 14)
                    }
                    .buttonStyle(.plain)
                    .help(copied ? "Copied!" : "Copy public URL")

                    Button {
                        guard let remoteURL = AWSV4Signer.presignedURL(for: object.key, credentials: credentials) else { return }
                        let panel = NSSavePanel()
                        panel.nameFieldStringValue = object.name
                        panel.canCreateDirectories = true
                        guard panel.runModal() == .OK, let dest = panel.url else { return }
                        onDownload(remoteURL, dest)
                    } label: {
                        Image(systemName: "arrow.down.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Download")

                    Button { showDeleteConfirm = true } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .help("Delete")
                }
                .frame(width: 80, alignment: .trailing)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if object.isFolder {
                onNavigate(object)
            } else {
                onPreview(object)
            }
        }
        .confirmationDialog(
            "Delete \"\(object.name)\"?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { onDelete(object) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove the file from R2 and cannot be undone.")
        }
    }

    // MARK: - Icon helpers

    var iconName: String {
        if object.isFolder { return "folder.fill" }
        let ext = (object.name as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff", "svg":
            return "photo"
        case "mp4", "mov", "avi", "mkv", "webm", "m4v":
            return "film"
        case "mp3", "m4a", "wav", "aac", "flac", "ogg":
            return "music.note"
        case "pdf":
            return "doc.richtext"
        case "zip", "tar", "gz", "bz2", "7z", "rar":
            return "archivebox"
        case "swift", "py", "js", "ts", "json", "xml", "html", "css", "sh", "rb", "go", "rs":
            return "chevron.left.forwardslash.chevron.right"
        case "doc", "docx":
            return "doc.text"
        case "xls", "xlsx":
            return "tablecells"
        case "ppt", "pptx":
            return "rectangle.on.rectangle"
        default:
            return "doc"
        }
    }

    private var iconColor: Color {
        let ext = (object.name as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff", "svg":
            return .purple
        case "mp4", "mov", "avi", "mkv", "webm", "m4v":
            return .pink
        case "mp3", "m4a", "wav", "aac", "flac", "ogg":
            return .orange
        case "pdf":
            return .red
        case "zip", "tar", "gz", "bz2", "7z", "rar":
            return .brown
        case "swift", "py", "js", "ts", "json", "xml", "html", "css", "sh", "rb", "go", "rs":
            return .mint
        default:
            return .secondary
        }
    }

    private var kindLabel: String {
        let ext = (object.name as NSString).pathExtension.uppercased()
        return ext.isEmpty ? "File" : "\(ext) File"
    }
}

// MARK: - Icon Grid Cell

struct R2IconCell: View {
    let object: R2Object
    let credentials: R2Credentials
    let isSelected: Bool
    let onNavigate: (R2Object) -> Void
    let onCopyURL: (String) -> Void

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
                    .frame(width: 64, height: 64)

                Image(systemName: R2ObjectRow(
                    object: object,
                    credentials: credentials,
                    isSelected: isSelected,
                    onNavigate: onNavigate,
                    onCopyURL: onCopyURL,
                    onPreview: { _ in },
                    onDownload: { _, _ in },
                    onDelete: { _ in }
                ).iconName)
                .font(.system(size: 36))
                .foregroundStyle(object.isFolder ? Color.accentColor : .secondary)
            }

            Text(object.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 80)
                .padding(.horizontal, 2)
        }
        .padding(4)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture(count: 2) {
            if object.isFolder { onNavigate(object) }
        }
    }
}
