import SwiftUI
#if os(macOS)
import AppKit
#endif

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
#if os(iOS)
    @State private var isDownloading = false
    @State private var shareItem: URL? = nil
#endif

    var body: some View {
#if os(iOS)
        iOSRow
#else
        macOSRow
#endif
    }

#if os(iOS)
    private var iOSRow: some View {
        HStack(spacing: 12) {
            Image(systemName: iosIconName)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(iosIconColor)
                .frame(width: 28, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(object.name)
                    .lineLimit(1)
                    .font(.body.weight(.medium))
                if object.isFolder {
                    Text(object.formattedDate)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(object.formattedSize) · \(object.formattedDate)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if object.isFolder {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                onDelete(object)
            } label: {
                Label("Delete", systemImage: "trash")
            }

            if !object.isFolder {
                Button {
                    guard !isDownloading,
                          let remoteURL = AWSV4Signer.presignedURL(for: object.key, credentials: credentials) else { return }
                    isDownloading = true
                    Task {
                        do {
                            let (tmpURL, _) = try await URLSession.shared.download(from: remoteURL)
                            // Move to a named temp file so the share sheet shows the right filename
                            let named = FileManager.default.temporaryDirectory
                                .appendingPathComponent(object.name)
                            try? FileManager.default.removeItem(at: named)
                            try FileManager.default.moveItem(at: tmpURL, to: named)
                            await MainActor.run {
                                shareItem = named
                                isDownloading = false
                            }
                        } catch {
                            await MainActor.run { isDownloading = false }
                        }
                    }
                } label: {
                    if isDownloading {
                        Label("Downloading…", systemImage: "arrow.down.circle")
                    } else {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                }
                .tint(.blue)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if !object.isFolder {
                Button {
                    let url = credentials.publicURL(forKey: object.key)
                    onCopyURL(url.absoluteString)
                    withAnimation(.easeInOut(duration: 0.15)) { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation(.easeInOut(duration: 0.2)) { copied = false }
                    }
                } label: {
                    Label(copied ? "Copied!" : "Copy URL", systemImage: copied ? "checkmark" : "link")
                }
                .tint(.indigo)
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
        .sheet(item: Binding(
            get: { shareItem.map { ShareableURL(url: $0) } },
            set: { if $0 == nil { shareItem = nil } }
        )) { shareable in
            ShareSheet(url: shareable.url)
                .presentationDetents([.medium, .large])
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .listRowBackground(Color.clear)
    }
#endif

    #if os(macOS)
    private var macOSRow: some View {
        HStack(spacing: 10) {
            // Explicit selection marker so selected rows are obvious.
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .opacity(isSelected ? 1 : 0)
                .frame(width: 14, alignment: .center)

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
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
        )
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
    #endif

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

#if os(iOS)
    private var iosIconName: String {
        if object.isFolder { return "folder.fill" }
        let ext = (object.name as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff", "svg":
            return "photo"
        case "mp4", "mov", "avi", "mkv", "webm", "m4v":
            return "video"
        case "pdf":
            return "doc.text"
        default:
            return "doc.fill"
        }
    }

    private var iosIconColor: Color {
        .accentColor
    }
#endif
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

// MARK: - iOS Share Sheet

#if os(iOS)
/// Wraps a URL as Identifiable so it can drive a .sheet(item:)
private struct ShareableURL: Identifiable {
    let id = UUID()
    let url: URL
}

/// UIActivityViewController wrapper for sharing/saving a downloaded file.
private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
