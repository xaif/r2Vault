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
        .glassEffect(.regular.tint(.green), in: .rect(cornerRadius: 10))
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
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 7))
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
            // Glass background — tinted blue when targeted
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.clear)
                .glassEffect(
                    isDropTargeted ? .regular.tint(.accentColor) : .regular,
                    in: .rect(cornerRadius: 10)
                )

            // Dashed border when idle
            if !isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        Color(NSColor.separatorColor),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                    )
            }

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
                // Cancel all button
                Button {
                    activeUploads.forEach { $0.cancel() }
                } label: {
                    Text("Cancel All")
                        .font(.system(size: 10))
                }
                .buttonStyle(.glass)
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
                }
                .buttonStyle(.glass)
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
    @State private var showDeleteConfirm = false

    var body: some View {
        HStack(spacing: 10) {
            // File type icon badge — glass with tint
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.clear)
                    .frame(width: 30, height: 30)
                    .glassEffect(.regular.tint(iconColor), in: .rect(cornerRadius: 6))
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
                HStack(spacing: 4) {
                    // Copy link
                    Button {
                        viewModel.copyToClipboard(item.publicURL.absoluteString)
                        withAnimation { copied = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation { copied = false }
                        }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "link")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(copied ? .green : .secondary)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.glass)
                    .help("Copy URL")

                    // Download
                    Button {
                        viewModel.downloadHistoryItem(item)
                    } label: {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.glass)
                    .help("Download to Downloads folder")

                    // Delete
                    Button {
                        showDeleteConfirm = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.red)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.glass)
                    .help("Delete from R2")
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? Color(NSColor.quaternaryLabelColor).opacity(0.5) : Color.clear)
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
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
