import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct MenuBarView: View {
    @Environment(AppViewModel.self) private var viewModel
    @State private var isDropTargeted = false

    private var activeUploads: [FileUploadTask] {
        viewModel.uploadTasks.filter { $0.status == .uploading || $0.status == .pending }
    }

    private var currentBucketItems: [UploadItem] {
        guard let bucket = viewModel.credentials?.bucketName else { return [] }
        return viewModel.historyStore.items.filter { $0.bucketName == bucket }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                dropZone
                    .padding(12)

                // Live upload progress — shown while uploads are active
                if !activeUploads.isEmpty {
                    uploadProgressSection
                }

                if !currentBucketItems.isEmpty {
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
        .frame(width: 320)
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
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .modifier(GlassToastModifier())
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

            // Settings menu — bucket switching + open main window + quit
            Menu {
                // Bucket section
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

                Divider()

                Button(role: .destructive) {
                    NSApp.terminate(nil)
                } label: {
                    Label("Quit R2 Vault", systemImage: "power")
                }
            } label: {
                Image(systemName: "gear")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .modifier(GlassGearModifier())
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
                      : Color(NSColor.quaternaryLabelColor).opacity(0.4))
                .modifier(GlassDropZoneModifier(isTargeted: isDropTargeted))

            if !isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        Color(NSColor.separatorColor),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                    )
            }

            VStack(spacing: 6) {
                Image(systemName: isDropTargeted ? "arrow.down.circle.fill" : "arrow.up.circle")
                    .font(.system(size: 28))
                    .foregroundStyle(isDropTargeted ? Color.accentColor : Color(NSColor.secondaryLabelColor))

                Text(isDropTargeted ? "Release to Upload" : "Drop files here or click to select")
                    .font(.system(size: 11))
                    .foregroundStyle(isDropTargeted ? Color.accentColor : Color(NSColor.secondaryLabelColor))
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 18)
        }
        .frame(height: 110)
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
            Divider()

            HStack {
                HStack(spacing: 5) {
                    ProgressView()
                        .scaleEffect(0.55)
                        .frame(width: 14, height: 14)
                    Text("Uploading \(activeUploads.filter { $0.status == .uploading }.count) of \(activeUploads.count)…")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                Spacer()
                Button {
                    activeUploads.forEach { $0.cancel() }
                } label: {
                    Text("Cancel All")
                        .font(.system(size: 10))
                }
                .modifier(GlassButtonModifier())
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
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(NSColor.tertiaryLabelColor))
                    .textCase(.uppercase)
                    .kerning(0.4)
                Spacer()
                Button {
                    openMainWindow()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(NSColor.secondaryLabelColor))
                }
                .buttonStyle(.borderless)
                .help("Open in main window")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(currentBucketItems.prefix(25)) { item in
                        MenuBarHistoryRow(item: item)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .trailing)),
                                removal: .opacity.combined(with: .move(edge: .trailing))
                                    .animation(.spring(response: 0.35, dampingFraction: 0.85))
                            ))
                    }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: viewModel.historyStore.items.map(\.id))
            }
            .frame(maxHeight: 260)
            .padding(.bottom, 6)
        }
    }

    // MARK: - Helpers

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.item]
        panel.title = "Select Files to Upload"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK else { return }
            viewModel.handleSelectedFiles(panel.urls)
        }
    }

    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        // Find the main app window — must be a titled window, not a panel or popover
        let appWindow = NSApp.windows.first {
            !($0 is NSPanel) &&
            $0.styleMask.contains(.titled) &&
            !$0.className.contains("StatusBar") &&
            !$0.className.contains("Popover")
        }
        if let window = appWindow {
            window.makeKeyAndOrderFront(nil)
        } else {
            // Window was closed — use SwiftUI's openWindow to reopen it
            viewModel.openMainWindow?()
        }
    }

    private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}

// MARK: - Availability-gated Glass Modifiers

/// Glass toast background — green tint on macOS 26+, solid green fill on older.
private struct GlassToastModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.tint(.green), in: .rect(cornerRadius: 10))
        } else {
            content
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.green.opacity(0.15))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.green.opacity(0.3), lineWidth: 1))
                )
        }
    }
}

/// Glass gear button — interactive glass on macOS 26+, subtle fill on older.
private struct GlassGearModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .rect(cornerRadius: 7))
        } else {
            content.background(RoundedRectangle(cornerRadius: 7).fill(Color(NSColor.quaternaryLabelColor).opacity(0.5)))
        }
    }
}

/// Glass drop zone — tinted glass on macOS 26+, plain fill on older.
private struct GlassDropZoneModifier: ViewModifier {
    let isTargeted: Bool
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(isTargeted ? .regular.tint(.accentColor) : .regular, in: .rect(cornerRadius: 10))
        } else {
            content // fill already applied on the RoundedRectangle
        }
    }
}

/// Glass button style — .glass on macOS 26+, .borderless on older.
private struct GlassButtonModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.borderless)
        }
    }
}

// MARK: - History Row

private struct MenuBarHistoryRow: View {
    let item: UploadItem
    @Environment(AppViewModel.self) private var viewModel
    @State private var isHovered = false
    @State private var copied = false
    @State private var showDeleteConfirm = false
    @State private var thumbnail: NSImage? = nil

    private var isImageOrVideo: Bool {
        let ext = (item.fileName as NSString).pathExtension.lowercased()
        return ["jpg","jpeg","png","gif","webp","heic","heif","bmp","tiff","svg",
                "mp4","mov","avi","mkv","webm","m4v"].contains(ext)
    }

    var body: some View {
        HStack(spacing: 8) {
            // Thumbnail or icon badge
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(NSColor.quaternaryLabelColor).opacity(0.6))
                    .frame(width: 30, height: 30)

                if let thumb = thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 30, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                } else {
                    Image(systemName: fileIcon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(iconColor)
                }
            }
            .task {
                guard isImageOrVideo, thumbnail == nil, let creds = viewModel.credentials else { return }
                thumbnail = await ThumbnailCache.shared.thumbnail(for: item.r2Key, credentials: creds)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(item.fileName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.formattedFileSize)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(NSColor.tertiaryLabelColor))
            }

            Spacer(minLength: 0)

            // Fixed-width action area — always occupies the same space so rows never shift
            HStack(spacing: 0) {
                actionButton(
                    icon: copied ? "checkmark" : "link",
                    tint: copied ? .green : .secondary,
                    help: "Copy URL"
                ) {
                    viewModel.copyToClipboard(item.publicURL.absoluteString)
                    withAnimation { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation { copied = false }
                    }
                }

                actionButton(icon: "arrow.down.circle", tint: .secondary, help: "Download") {
                    viewModel.downloadHistoryItem(item)
                }

                actionButton(icon: "trash", tint: .red, help: "Delete") {
                    showDeleteConfirm = true
                }
            }
            .opacity(isHovered ? 1 : 0)
            // Always reserve the space even when hidden
            .frame(width: 72)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? Color(NSColor.quaternaryLabelColor).opacity(0.45) : Color.clear)
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .animation(.easeOut(duration: 0.15), value: copied)
        .confirmationDialog(
            "Delete \"\(item.fileName)\"?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                viewModel.deleteHistoryItem(item)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove the file from R2 and cannot be undone.")
        }
    }

    @ViewBuilder
    private func actionButton(icon: String, tint: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
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
                .foregroundStyle(task.status == .pending ? Color.secondary : Color.accentColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(task.fileName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(task.status == .pending ? "Waiting" : "\(Int(task.progress * 100))%")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                if task.status == .uploading {
                    ProgressView(value: task.progress)
                        .progressViewStyle(.linear)
                        .tint(Color.accentColor)
                        .frame(height: 3)
                } else {
                    Rectangle()
                        .fill(Color(NSColor.separatorColor))
                        .frame(height: 3)
                        .clipShape(Capsule())
                }
            }

            Button { task.cancel() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Cancel")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }
}
