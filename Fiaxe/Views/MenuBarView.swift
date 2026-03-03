import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct MenuBarView: View {
    @Environment(AppViewModel.self) private var viewModel
    @State private var isDropTargeted = false

    private var activeUploads: [FileUploadTask] {
        viewModel.uploadTasks.filter { $0.status == .uploading || $0.status == .pending }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                    .overlay(Color.white.opacity(0.07))
                dropZone
                    .padding(12)

                // Live upload progress — shown while uploads are active
                if !activeUploads.isEmpty {
                    uploadProgressSection
                }

                if !viewModel.historyStore.items.isEmpty {
                    recentUploadsSection
                }
            }

            // "Link copied!" toast
            if viewModel.clipboardToastFileName != nil {
                linkCopiedToast
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(10)
            }
        }
        .frame(width: 300)
        .background(Color(red: 0.13, green: 0.13, blue: 0.14))
        .colorScheme(.dark)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: viewModel.clipboardToastFileName != nil)
    }

    private var linkCopiedToast: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text("Link copied!")
                    .font(.system(size: 12, weight: .semibold))
                if let name = viewModel.clipboardToastFileName {
                    Text(name)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.55))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(red: 0.1, green: 0.28, blue: 0.15).opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.green.opacity(0.3), lineWidth: 1)
                )
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            // App icon
            if let appIcon = NSImage(named: NSImage.applicationIconName) {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }

            Text("R2 Vault")
                .font(.system(size: 13, weight: .semibold))

            Spacer()

            // Settings menu — bucket switching + open main window
            Menu {
                // Bucket section (always shown if credentials exist)
                if !viewModel.credentialsList.isEmpty {
                    if viewModel.credentialsList.count > 1 {
                        Section("Switch Bucket") {
                            ForEach(viewModel.credentialsList) { creds in
                                Button {
                                    viewModel.selectCredentials(id: creds.id)
                                } label: {
                                    HStack {
                                        Text(creds.bucketName)
                                        if creds.id == viewModel.credentials?.id {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }
                        Divider()
                    } else if let bucket = viewModel.credentials?.bucketName {
                        Text(bucket)
                            .foregroundStyle(.secondary)
                        Divider()
                    }
                }

                Button {
                    openMainWindow()
                } label: {
                    Label("Open R2 Vault", systemImage: "arrow.up.right.square")
                }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(NSColor.secondaryLabelColor))
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.07)))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    // MARK: - Drop Zone

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(isDropTargeted
                      ? Color.accentColor.opacity(0.12)
                      : Color.white.opacity(0.05))

            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color.white.opacity(0.15),
                    style: StrokeStyle(
                        lineWidth: isDropTargeted ? 2 : 1.5,
                        dash: isDropTargeted ? [] : [6, 4]
                    )
                )

            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(isDropTargeted ? Color.accentColor.opacity(0.15) : Color(NSColor.quaternaryLabelColor).opacity(0.3))
                        .frame(width: 36, height: 36)
                    Image(systemName: isDropTargeted ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(isDropTargeted ? Color.accentColor : Color(NSColor.secondaryLabelColor))
                }

                VStack(spacing: 2) {
                    Text(isDropTargeted ? "Release to Upload" : "Drop files here")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isDropTargeted ? Color.accentColor : Color(NSColor.labelColor))

                    if !isDropTargeted {
                        Text("or click to browse")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(NSColor.secondaryLabelColor))
                    }
                }
            }
            .padding(.vertical, 16)
        }
        .frame(height: 100)
        .contentShape(Rectangle())
        .onTapGesture { openFilePicker() }
        .dropDestination(for: URL.self) { urls, _ in
            guard viewModel.hasCredentials else { return false }
            viewModel.handleDroppedURLs(urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: isDropTargeted)
    }

    // MARK: - Upload Progress

    private var uploadProgressSection: some View {
        VStack(spacing: 0) {
            Divider().overlay(Color.white.opacity(0.07))

            HStack {
                HStack(spacing: 5) {
                    ProgressView()
                        .scaleEffect(0.55)
                        .frame(width: 14, height: 14)
                    Text("Uploading \(activeUploads.filter { $0.status == .uploading }.count) of \(activeUploads.count)…")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.85))
                }
                Spacer()
                // Cancel all button
                Button {
                    activeUploads.forEach { $0.cancel() }
                } label: {
                    Text("Cancel All")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)

            VStack(spacing: 1) {
                ForEach(activeUploads) { task in
                    MenuBarUploadRow(task: task)
                }
            }
            .padding(.bottom, 8)
        }
    }

    // MARK: - Recent Uploads

    private var recentUploadsSection: some View {
        VStack(spacing: 0) {
            Divider()

            HStack {
                Text("Recent Uploads")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(NSColor.secondaryLabelColor))
                    .textCase(.uppercase)
                Spacer()
                Button {
                    openMainWindow()
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(NSColor.secondaryLabelColor))
                }
                .buttonStyle(.borderless)
                .help("Open main window")
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(viewModel.historyStore.items.prefix(25)) { item in
                        MenuBarHistoryRow(item: item)
                    }
                }
            }
            .frame(maxHeight: 260)
            .padding(.bottom, 6)
        }
    }

    // MARK: - Helpers

    /// Opens NSOpenPanel imperatively so the menu bar popover doesn't lose focus and dismiss.
    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.item]
        panel.title = "Select Files to Upload"
        // Make sure the panel becomes key window without closing the popover
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK else { return }
            viewModel.handleSelectedFiles(panel.urls)
        }
    }

    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { !$0.className.contains("StatusBar") && $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

// MARK: - History Row

private struct MenuBarHistoryRow: View {
    let item: UploadItem
    @Environment(AppViewModel.self) private var viewModel
    @State private var isHovered = false
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            // File type icon badge
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(iconBackground)
                    .frame(width: 30, height: 30)
                Image(systemName: fileIcon)
                    .font(.system(size: 13))
                    .foregroundStyle(iconColor)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(item.fileName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.formattedFileSize)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(NSColor.secondaryLabelColor))
            }

            Spacer()

            // Action buttons — visible on hover
            if isHovered {
                HStack(spacing: 2) {
                    // Copy link
                    rowActionButton(
                        icon: copied ? "checkmark" : "link",
                        tint: copied ? .green : Color(NSColor.secondaryLabelColor),
                        help: "Copy URL"
                    ) {
                        viewModel.copyToClipboard(item.publicURL.absoluteString)
                        withAnimation { copied = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation { copied = false }
                        }
                    }

                    // Download
                    rowActionButton(
                        icon: "arrow.down.circle",
                        tint: Color(NSColor.secondaryLabelColor),
                        help: "Download to Downloads folder"
                    ) {
                        viewModel.downloadHistoryItem(item)
                    }

                    // Delete
                    rowActionButton(
                        icon: "trash",
                        tint: .red,
                        help: "Delete from R2"
                    ) {
                        viewModel.deleteHistoryItem(item)
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? Color.white.opacity(0.07) : Color.clear)
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.15), value: copied)
    }

    @ViewBuilder
    private func rowActionButton(icon: String, tint: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(NSColor.quaternaryLabelColor).opacity(0.5))
                )
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private var fileIcon: String {
        let ext = (item.fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff", "svg": return "photo.fill"
        case "mp4", "mov", "avi", "mkv", "webm", "m4v": return "film.fill"
        case "mp3", "m4a", "wav", "aac", "flac", "ogg": return "music.note"
        case "pdf": return "doc.richtext.fill"
        case "zip", "tar", "gz", "bz2", "7z", "rar": return "archivebox.fill"
        case "swift", "py", "js", "ts", "json", "xml", "html", "css", "sh": return "chevron.left.forwardslash.chevron.right"
        default: return "doc.fill"
        }
    }

    private var iconBackground: Color {
        let ext = (item.fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff", "svg": return Color.purple.opacity(0.15)
        case "mp4", "mov", "avi", "mkv", "webm", "m4v": return Color.pink.opacity(0.15)
        case "mp3", "m4a", "wav", "aac", "flac", "ogg": return Color.orange.opacity(0.15)
        case "pdf": return Color.red.opacity(0.15)
        case "zip", "tar", "gz", "bz2", "7z", "rar": return Color.brown.opacity(0.15)
        default: return Color.blue.opacity(0.12)
        }
    }

    private var iconColor: Color {
        let ext = (item.fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff", "svg": return .purple
        case "mp4", "mov", "avi", "mkv", "webm", "m4v": return .pink
        case "mp3", "m4a", "wav", "aac", "flac", "ogg": return .orange
        case "pdf": return .red
        case "zip", "tar", "gz", "bz2", "7z", "rar": return Color(NSColor.brown)
        default: return .blue
        }
    }
}

// MARK: - Active Upload Row

private struct MenuBarUploadRow: View {
    let task: FileUploadTask

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: task.status == .pending ? "clock" : "arrow.up.circle")
                .font(.system(size: 12))
                .foregroundStyle(task.status == .pending ? Color.white.opacity(0.3) : Color.accentColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(task.fileName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(task.status == .pending ? "Waiting" : "\(Int(task.progress * 100))%")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.4))
                        .monospacedDigit()
                }

                if task.status == .uploading {
                    ProgressView(value: task.progress)
                        .progressViewStyle(.linear)
                        .tint(Color.accentColor)
                        .frame(height: 3)
                } else {
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 3)
                        .clipShape(Capsule())
                }
            }

            Button { task.cancel() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.25))
            }
            .buttonStyle(.borderless)
            .help("Cancel")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }
}
