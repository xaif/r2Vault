import SwiftUI

/// Finder-like R2 bucket browser with Icons / List / Gallery view modes,
/// Finder-style toolbar, path bar, multi-select, and drag-and-drop upload.
struct BrowserView: View {
    @Environment(AppViewModel.self) private var viewModel
    @State private var showNewFolderSheet = false
    @State private var newFolderName = ""
    @State private var isDropTargeted = false
    @State private var showDeleteConfirm = false

    var body: some View {
        @Bindable var vm = viewModel

        VStack(spacing: 0) {
            // Path bar
            if viewModel.credentials != nil {
                pathBar
                Divider()
            }

            // Content
            ZStack {
                mainContent
                    .dropDestination(for: URL.self) { urls, _ in
                        guard viewModel.hasCredentials else { return false }
                        viewModel.handleDroppedURLs(urls)
                        return true
                    } isTargeted: { isDropTargeted = $0 }
                if isDropTargeted { dropOverlay }
            }
            .animation(.easeInOut(duration: 0.2), value: viewModel.isBrowsing)
            .animation(.easeInOut(duration: 0.2), value: viewModel.browserError)

            // Status bar
            statusBar
        }
        .searchable(text: $vm.filterText, placement: .toolbar, prompt: "Search")
        .toolbar { toolbarContent }
        .onAppear {
            if viewModel.browserObjects.isEmpty && viewModel.browserFolders.isEmpty && !viewModel.isBrowsing {
                viewModel.loadCurrentFolder()
            }
        }
        .sheet(isPresented: $showNewFolderSheet) { newFolderSheet }
        .confirmationDialog(
            "Delete \(viewModel.selectedObjectIDs.count) item\(viewModel.selectedObjectIDs.count == 1 ? "" : "s")?",
            isPresented: $showDeleteConfirm, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { Task { await viewModel.deleteSelected() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove the selected items from R2 and cannot be undone.")
        }
    }

    // MARK: - Path Bar

    private var pathBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                pathCrumb(
                    label: viewModel.credentials?.bucketName ?? "Bucket",
                    systemImage: "externaldrive.fill",
                    isCurrent: viewModel.pathSegments.isEmpty
                ) { viewModel.navigateToRoot() }

                ForEach(Array(viewModel.pathSegments.enumerated()), id: \.offset) { idx, segment in
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .transition(.opacity)
                    pathCrumb(
                        label: segment,
                        systemImage: "folder.fill",
                        isCurrent: idx == viewModel.pathSegments.count - 1
                    ) { viewModel.navigateToSegment(idx) }
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
                }
            }
            .padding(.horizontal, 14)
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: viewModel.pathSegments)
        }
        .frame(height: 30)
        .background(.regularMaterial)
    }

    private func pathCrumb(label: String, systemImage: String, isCurrent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 11))
                Text(label)
                    .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
            }
            .foregroundStyle(isCurrent ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Color.accentColor))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(isCurrent ? Color.secondary.opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .disabled(isCurrent)
    }

    // MARK: - Main Content

    @ViewBuilder
    private var mainContent: some View {
        if viewModel.isBrowsing {
            loadingView
        } else if let error = viewModel.browserError {
            errorView(error)
        } else if !viewModel.hasCredentials {
            noCredentialsView
        } else if viewModel.allBrowserItems.isEmpty {
            emptyView
        } else {
            switch viewModel.viewMode {
            case .icons: iconsView
            case .list:  listView
            }
        }
    }

    // MARK: - Icons View

    private var iconsView: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 120, maximum: 140), spacing: 12)],
                spacing: 12
            ) {
                ForEach(viewModel.allBrowserItems) { item in
                    FinderIconCell(
                        object: item,
                        credentials: viewModel.credentials ?? .empty,
                        isSelected: viewModel.selectedObjectIDs.contains(item.id)
                    )
                        .onTapGesture(count: 2) {
                            if item.isFolder {
                                viewModel.navigateToFolder(item)
                            } else {
                                QuickLookCoordinator.shared.preview(
                                    item,
                                    credentials: viewModel.credentials ?? .empty
                                )
                            }
                        }
                    .contextMenu { rowContextMenu(for: item) }
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
            .padding(16)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: viewModel.allBrowserItems.map(\.id))
        }
        .background(Color(NSColor.controlBackgroundColor))
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.15)) {
                viewModel.clearSelection()
            }
        }
    }

    // MARK: - List View

    private var listView: some View {
        VStack(spacing: 0) {
            listHeader
            Divider()
            List {
                ForEach(viewModel.allBrowserItems) { item in
                    R2ObjectRow(
                        object: item,
                        credentials: viewModel.credentials ?? .empty,
                        isSelected: false,
                        onNavigate: { viewModel.navigateToFolder($0) },
                        onCopyURL: { viewModel.copyToClipboard($0) },
                        onPreview: { QuickLookCoordinator.shared.preview($0, credentials: viewModel.credentials ?? .empty) },
                        onDownload: { viewModel.downloadToDestination(from: $0, dest: $1) },
                        onDelete: { item in Task { await viewModel.deleteObject(item) } }
                    )
                    .contextMenu { rowContextMenu(for: item) }
                }
            }
            .listStyle(.inset)
        }
    }

    private var listHeader: some View {
        HStack(spacing: 8) {
            Spacer().frame(width: 28)
            colHeaderBtn("Name", .name).frame(maxWidth: .infinity, alignment: .leading)
            colHeaderBtn("Kind",  .kind).frame(width: 80, alignment: .trailing)
            colHeaderBtn("Size",  .size).frame(width: 72, alignment: .trailing)
            colHeaderBtn("Date Modified", .date).frame(width: 140, alignment: .trailing)
            Spacer().frame(width: 28)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private func colHeaderBtn(_ title: String, _ key: BrowserSortKey) -> some View {
        Button {
            if viewModel.sortKey == key { viewModel.sortAscending.toggle() }
            else { viewModel.sortKey = key; viewModel.sortAscending = true }
        } label: {
            HStack(spacing: 2) {
                Text(title).font(.caption).foregroundStyle(viewModel.sortKey == key ? .primary : .secondary)
                if viewModel.sortKey == key {
                    Image(systemName: viewModel.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty / Loading / Error

    private var emptyView: some View {
        ZStack {
            Color(NSColor.controlBackgroundColor).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "arrow.up.to.line.compact")
                    .font(.system(size: 48)).foregroundStyle(.quaternary)
                Text("Drop Files to Upload")
                    .font(.title3).fontWeight(.semibold).foregroundStyle(.secondary)
                Text("Or click + in the toolbar")
                    .font(.subheadline).foregroundStyle(.tertiary)
                Button { viewModel.showFileImporter = true } label: {
                    Label("Select Files…", systemImage: "plus.circle.fill")
                        .padding(.horizontal, 14).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent).padding(.top, 4)
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 10) {
            ProgressView().scaleEffect(1.1)
            Text("Loading…").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func errorView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Failed to Load", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Retry") { viewModel.loadCurrentFolder() }.buttonStyle(.borderedProminent)
        }
    }

    private var noCredentialsView: some View {
        ContentUnavailableView {
            Label("No Credentials", systemImage: "key.slash")
        } description: {
            Text("Open Settings (⌘,) to configure your R2 access keys.")
        } actions: {
            Button("Open Settings") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Drop Overlay

    private var dropOverlay: some View {
        ZStack {
            Color.accentColor.opacity(0.07)
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, dash: [8, 5]))
                .padding(10)
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 48)).foregroundStyle(Color.accentColor)
                Text("Drop to upload here")
                    .font(.title3).fontWeight(.semibold).foregroundStyle(Color.accentColor)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        let total = viewModel.allBrowserItems.count
        let sel   = viewModel.selectedObjectIDs.count
        return Group {
            if total > 0 || sel > 0 {
                HStack(spacing: 10) {
                    if sel > 0 {
                        Text("\(sel) of \(total) selected").foregroundStyle(.secondary)
                        Spacer()
                        Button(role: .destructive) { showDeleteConfirm = true } label: {
                            Label("Delete Selected", systemImage: "trash")
                        }
                        .buttonStyle(.plain).foregroundStyle(.red)
                        Button { viewModel.clearSelection() } label: { Text("Deselect") }
                            .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    } else {
                        Text("\(total) item\(total == 1 ? "" : "s")").foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                .font(.caption)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
            }
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func rowContextMenu(for item: R2Object) -> some View {
        if item.isFolder {
            Button { viewModel.navigateToFolder(item) } label: {
                Label("Open", systemImage: "arrow.right.circle")
            }
            Divider()
        } else {
            Button {
                QuickLookCoordinator.shared.preview(item, credentials: viewModel.credentials ?? .empty)
            } label: {
                Label("Preview", systemImage: "eye")
            }
            Button {
                let url = (viewModel.credentials ?? .empty).publicURL(forKey: item.key)
                viewModel.copyToClipboard(url.absoluteString)
            } label: {
                Label("Copy URL", systemImage: "doc.on.clipboard")
            }
            Divider()
        }
        Button { viewModel.selectedObjectIDs.insert(item.id) } label: {
            Label("Select", systemImage: "checkmark.circle")
        }
        Divider()
        Button(role: .destructive) { Task { await viewModel.deleteObject(item) } } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Back / Forward buttons — left navigation area
        ToolbarItem(placement: .navigation) {
            Button { viewModel.navigateBack() } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!viewModel.canGoBack)
            .help("Back")
        }
        ToolbarItem(placement: .navigation) {
            Button { viewModel.navigateForward() } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!viewModel.canGoForward)
            .help("Forward")
        }

        // Compact segmented view mode picker
        ToolbarItem(placement: .primaryAction) {
            Picker("View", selection: Binding(
                get: { viewModel.viewMode },
                set: { viewModel.viewMode = $0 }
            )) {
                Image(systemName: "list.bullet").tag(BrowserViewMode.list)
                Image(systemName: "square.grid.2x2").tag(BrowserViewMode.icons)
            }
            .pickerStyle(.segmented)
            .frame(width: 72)
            .help("View Mode")
        }

        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed)
        }

        // Upload actions
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("Upload Files…") { viewModel.showFileImporter = true }
                Button("Upload Folder…") { viewModel.showFolderImporter = true }
                Divider()
                Button("New Folder…") { newFolderName = ""; showNewFolderSheet = true }
            } label: {
                Image(systemName: "plus")
            }
            .disabled(!viewModel.hasCredentials)
            .help("Upload")
        }

        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed)
        }

        // Utility actions
        ToolbarItemGroup(placement: .primaryAction) {
            Button { viewModel.loadCurrentFolder() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(!viewModel.hasCredentials)
            .help("Refresh")

            sortMenu
            selectionMenu
        }


    }

    // MARK: - Sort Menu

    private var sortMenu: some View {
        Menu {
            ForEach(BrowserSortKey.allCases) { key in
                Button {
                    if viewModel.sortKey == key { viewModel.sortAscending.toggle() }
                    else { viewModel.sortKey = key; viewModel.sortAscending = true }
                } label: {
                    HStack {
                        Text(key.rawValue)
                        if viewModel.sortKey == key {
                            Image(systemName: viewModel.sortAscending ? "chevron.up" : "chevron.down")
                        }
                    }
                }
            }
            Divider()
            Button { viewModel.sortAscending.toggle() } label: {
                Label(viewModel.sortAscending ? "Ascending" : "Descending",
                      systemImage: viewModel.sortAscending ? "arrow.up" : "arrow.down")
            }
        } label: { Image(systemName: "arrow.up.arrow.down") }
        .help("Sort by…")
    }

    // MARK: - Selection Menu

    private var selectionMenu: some View {
        Menu {
            Button { viewModel.selectAll() } label: {
                Label("Select All", systemImage: "checkmark.circle")
            }
            Button { viewModel.clearSelection() } label: {
                Label("Deselect All", systemImage: "xmark.circle")
            }
            if !viewModel.selectedObjectIDs.isEmpty {
                Divider()
                Button(role: .destructive) { showDeleteConfirm = true } label: {
                    Label("Delete Selected (\(viewModel.selectedObjectIDs.count))", systemImage: "trash")
                }
            }
        } label: { Image(systemName: "checkmark.circle") }
        .help("Select…")
    }

    // MARK: - New Folder Sheet

    private var newFolderSheet: some View {
        VStack(spacing: 18) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 32)).foregroundStyle(Color.accentColor)
            Text("New Folder").font(.headline)
            TextField("Folder name", text: $newFolderName)
                .textFieldStyle(.roundedBorder).frame(width: 260)
                .onSubmit { commitNewFolder() }
            HStack(spacing: 10) {
                Button("Cancel") { showNewFolderSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { commitNewFolder() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(26).frame(minWidth: 310)
    }

    private func commitNewFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        showNewFolderSheet = false
        Task { await viewModel.createFolder(name: name) }
    }

    // MARK: - Helpers

    private var selectionBinding: Binding<Set<UUID>> {
        Binding(get: { viewModel.selectedObjectIDs }, set: { viewModel.selectedObjectIDs = $0 })
    }

    private func toggleSelection(_ item: R2Object) {
        if viewModel.selectedObjectIDs.contains(item.id) {
            viewModel.selectedObjectIDs.remove(item.id)
        } else {
            viewModel.selectedObjectIDs.insert(item.id)
        }
    }

    private func iconName(for item: R2Object) -> String {
        if item.isFolder { return "folder.fill" }
        let ext = (item.name as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg","jpeg","png","gif","webp","heic","heif","bmp","tiff","svg": return "photo"
        case "mp4","mov","avi","mkv","webm","m4v": return "film"
        case "mp3","m4a","wav","aac","flac","ogg": return "music.note"
        case "pdf": return "doc.richtext"
        case "zip","tar","gz","bz2","7z","rar": return "archivebox"
        case "swift","py","js","ts","json","xml","html","css","sh","rb","go","rs":
            return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }
}

// MARK: - Finder Icon Cell

struct FinderIconCell: View {
    let object: R2Object
    let credentials: R2Credentials
    let isSelected: Bool

    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 6) {
            ThumbnailView(object: object, credentials: credentials, size: 72)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                )
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(NSColor.controlBackgroundColor))
                )
                .scaleEffect(isHovered && !isSelected ? 1.04 : 1.0)

            Text(object.name)
                .font(.caption2)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(maxWidth: 120)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    isSelected
                        ? Color.accentColor.opacity(0.12)
                        : (isHovered ? Color.secondary.opacity(0.08) : Color.clear)
                )
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .animation(.easeOut(duration: 0.15), value: isSelected)
    }
}

// MARK: - R2Credentials convenience

extension R2Credentials {
    static let empty = R2Credentials(accountId: "", accessKeyId: "", secretAccessKey: "", bucketName: "")
}

#Preview {
    BrowserView()
        .environment(AppViewModel())
        .frame(width: 860, height: 580)
}
