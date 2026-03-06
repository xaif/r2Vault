import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
import QuickLook
import UIKit
#endif

/// Finder-like R2 bucket browser with Icons / List view modes,
/// path bar, multi-select, and drag-and-drop upload (macOS).
struct BrowserView: View {
    @Environment(AppViewModel.self) private var viewModel
    @State private var showNewFolderSheet = false
    @State private var newFolderName = ""
    @State private var isDropTargeted = false
    @State private var showDeleteConfirm = false
    @State private var pendingDeleteItem: R2Object? = nil
#if os(iOS)
    @State private var photosPickerSelection: [PhotosPickerItem] = []
    @State private var swipeOffset: CGFloat = 0
    @State private var swipeDirection: SwipeDirection = .none
    @State private var previewItem: PreviewFile? = nil
    @State private var isPreparingPreview = false
    @State private var previewLoadingName: String? = nil
    @State private var navigationAnimationDirection: NavigationAnimationDirection = .forward

    private enum SwipeDirection { case none, back, forward }
    private enum NavigationAnimationDirection { case forward, back }
    private let swipeThreshold: CGFloat = 60
    private let swipeActivationEdgeWidth: CGFloat = 28
#endif

    var body: some View {
        @Bindable var vm = viewModel

        VStack(spacing: 0) {
#if os(macOS)
            // Path bar (macOS only — on iOS the navigation title serves this purpose)
            if viewModel.credentials != nil {
                pathBar
                Divider()
            }
#endif

            // Content
            ZStack {
#if os(macOS)
                mainContent
                    .dropDestination(for: URL.self) { urls, _ in
                        guard viewModel.hasCredentials else { return false }
                        Task { @MainActor in
                            viewModel.handleDroppedURLs(urls)
                        }
                        return true
                    } isTargeted: { isDropTargeted = $0 }
                if isDropTargeted { dropOverlay }
#else
                ZStack {
                    mainContent
                        .id(viewModel.currentPrefix)
                        .transition(folderNavigationTransition)
                }
                .clipped()
                    .offset(x: swipeOffset)
                    .simultaneousGesture(edgeSwipeGesture)
                if isNavigatingFolders {
                    folderLoadingOverlay
                }
                if isPreparingPreview {
                    previewLoadingOverlay
                }
#endif
            }
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
#if os(iOS)
        .onChange(of: viewModel.currentPrefix) { _, _ in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                swipeOffset = 0
            }
        }
        .animation(.easeInOut(duration: 0.26), value: viewModel.currentPrefix)
        .sheet(item: $previewItem, onDismiss: deletePreviewFileIfNeeded) { item in
            QuickLookPreviewSheet(url: item.url)
                .ignoresSafeArea()
        }
#endif
        .sheet(isPresented: $showNewFolderSheet) { newFolderSheet }
        .confirmationDialog(
            "Delete \(viewModel.selectedObjectIDs.count) item\(viewModel.selectedObjectIDs.count == 1 ? "" : "s")?",
            isPresented: $showDeleteConfirm, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { Task { await viewModel.deleteSelected() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove the selected items from R2 and cannot be undone. Folders will be deleted recursively including all their contents.")
        }
        .confirmationDialog(
            pendingDeleteItem.map { $0.isFolder ? "Delete \"\($0.name)\" and all its contents?" : "Delete \"\($0.name)\"?" } ?? "",
            isPresented: Binding(get: { pendingDeleteItem != nil }, set: { if !$0 { pendingDeleteItem = nil } }),
            titleVisibility: .visible
        ) {
            Button(pendingDeleteItem?.isFolder == true ? "Delete Folder & Contents" : "Delete", role: .destructive) {
                if let item = pendingDeleteItem {
                    Task { await viewModel.deleteObject(item) }
                    pendingDeleteItem = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingDeleteItem = nil }
        } message: {
            if let item = pendingDeleteItem {
                if item.isFolder {
                    Text("This will permanently delete the folder and all files inside it from R2. This cannot be undone.")
                } else {
                    Text("This will permanently remove the file from R2. This cannot be undone.")
                }
            }
        }
        // iOS file importer
        .fileImporter(
            isPresented: $vm.showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task { @MainActor in
                    viewModel.handleSelectedFiles(urls)
                }
            case .failure(let error):
                vm.alertMessage = error.localizedDescription
                vm.showAlert = true
            }
        }
#if os(iOS)
        // iOS photo picker
        .photosPicker(
            isPresented: $vm.showPhotoPicker,
            selection: $photosPickerSelection,
            maxSelectionCount: 20,
            matching: .any(of: [.images, .videos]),
            photoLibrary: .shared()
        )
        .onChange(of: photosPickerSelection) { _, newItems in
            if !newItems.isEmpty {
                handleSelectedPhotos(newItems)
                photosPickerSelection = []
            }
        }
#endif
    }

    // MARK: - Path Bar

    private var pathBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                pathCrumb(
                    label: viewModel.credentials?.bucketName ?? "Bucket",
                    systemImage: "externaldrive.fill",
                    isCurrent: viewModel.pathSegments.isEmpty
                ) { navigateToRootAnimated() }

                ForEach(Array(viewModel.pathSegments.enumerated()), id: \.offset) { idx, segment in
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .transition(.opacity)
                    pathCrumb(
                        label: segment,
                        systemImage: "folder.fill",
                        isCurrent: idx == viewModel.pathSegments.count - 1
                    ) { navigateToSegmentAnimated(idx) }
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
                }
            }
            .padding(.horizontal, 14)
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: viewModel.pathSegments)
        }
#if os(iOS)
        .frame(height: 40)
#else
        .frame(height: 30)
#endif
        .background(.regularMaterial)
    }

    private func pathCrumb(label: String, systemImage: String, isCurrent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: systemImage)
#if os(iOS)
                    .font(.system(size: 13))
#else
                    .font(.system(size: 11))
#endif
                Text(label)
#if os(iOS)
                    .font(.system(size: 14, weight: isCurrent ? .semibold : .regular))
#else
                    .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
#endif
            }
            .foregroundStyle(isCurrent ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Color.accentColor))
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(isCurrent ? Color.secondary.opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(isCurrent)
    }

    // MARK: - Main Content

    @ViewBuilder
    private var mainContent: some View {
        if viewModel.isBrowsing && viewModel.browserObjects.isEmpty && viewModel.browserFolders.isEmpty {
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
                columns: [GridItem(.adaptive(minimum: 100, maximum: 130), spacing: 10)],
                spacing: 10
            ) {
                ForEach(viewModel.allBrowserItems) { item in
                    FinderIconCell(
                        object: item,
                        credentials: viewModel.credentials ?? .empty,
                        isSelected: viewModel.selectedObjectIDs.contains(item.id)
                    )
#if os(macOS)
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
                    .onTapGesture(count: 1) {
                        toggleSelection(item)
                    }
#else
                    .onTapGesture {
                        if item.isFolder {
                            navigateToFolderAnimated(item)
                        } else {
                            previewFile(item)
                        }
                    }
                    .onLongPressGesture {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            toggleSelection(item)
                        }
                    }
#endif
                    .contextMenu { rowContextMenu(for: item) }
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
            .padding(16)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: viewModel.allBrowserItems.map(\.id))
        }
        .background(Color.secondary.opacity(0.05))
#if os(macOS)
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.15)) {
                viewModel.clearSelection()
            }
        }
#endif
    }

    // MARK: - List View

    private var listView: some View {
        VStack(spacing: 0) {
#if os(macOS)
            listHeader
            Divider()
#endif
            List {
                ForEach(viewModel.allBrowserItems) { item in
                    R2ObjectRow(
                        object: item,
                        credentials: viewModel.credentials ?? .empty,
                        isSelected: viewModel.selectedObjectIDs.contains(item.id),
                        onNavigate: { navigateToFolderAnimated($0) },
                        onCopyURL: { viewModel.copyToClipboard($0) },
                        onPreview: {
#if os(macOS)
                            QuickLookCoordinator.shared.preview($0, credentials: viewModel.credentials ?? .empty)
#else
                            _ = $0
#endif
                        },
                        onDownload: { viewModel.downloadToDestination(from: $0, dest: $1) },
                        onDelete: { item in Task { await viewModel.deleteObject(item) } }
                    )
#if os(macOS)
                    .onTapGesture { toggleSelection(item) }
#else
                    .onTapGesture {
                        if item.isFolder {
                            navigateToFolderAnimated(item)
                        } else {
                            previewFile(item)
                        }
                    }
                    .onLongPressGesture {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            toggleSelection(item)
                        }
                    }
#endif
                    .contextMenu { rowContextMenu(for: item) }
                }
            }
#if os(iOS)
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.black)
#else
            .listStyle(.inset)
#endif
        }
    }

#if os(macOS)
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
#endif

    // MARK: - Empty / Loading / Error

    private var emptyView: some View {
        ZStack {
            Color.secondary.opacity(0.05).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "arrow.up.to.line.compact")
                    .font(.system(size: 48)).foregroundStyle(.quaternary)
                Text("No Files Here")
                    .font(.title3).fontWeight(.semibold).foregroundStyle(.secondary)
                Text("Tap + to upload files")
                    .font(.subheadline).foregroundStyle(.tertiary)
                Button { viewModel.presentFilePicker() } label: {
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
        .background(Color.secondary.opacity(0.05))
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
            Text("Open Settings to configure your R2 access keys.")
        } actions: {
#if os(macOS)
            Button("Open Settings") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            .buttonStyle(.borderedProminent)
#endif
        }
    }

    // MARK: - Drop Overlay (macOS only)

#if os(macOS)
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
#endif

    // MARK: - Status Bar

    private var statusBar: some View {
        let total = viewModel.allBrowserItems.count
        let sel   = viewModel.selectedObjectIDs.count
        return Group {
#if os(macOS)
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
#else
            // iOS: no idle count bar — selection shown as floating pill
            EmptyView()
#endif
        }
    }



    // MARK: - Context Menu

    @ViewBuilder
    private func rowContextMenu(for item: R2Object) -> some View {
        if item.isFolder {
            Button { navigateToFolderAnimated(item) } label: {
                Label("Open", systemImage: "arrow.right.circle")
            }
            Divider()
        } else {
#if os(macOS)
            Button {
                QuickLookCoordinator.shared.preview(item, credentials: viewModel.credentials ?? .empty)
            } label: {
                Label("Preview", systemImage: "eye")
            }
#else
            Button {
                previewFile(item)
            } label: {
                Label("Preview", systemImage: "eye")
            }
#endif
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
        Button(role: .destructive) { pendingDeleteItem = item } label: {
            Label(item.isFolder ? "Delete Folder & Contents" : "Delete", systemImage: "trash")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
#if os(macOS)
        // Back / Forward buttons — macOS left navigation area
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
#else
        // iOS: show a "Back" button in the navigation bar only when inside a subfolder
        if !viewModel.pathSegments.isEmpty {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    navigateBackAnimated()
                } label: {
                    Image(systemName: "chevron.left")
                        .fontWeight(.semibold)
                }
                .accessibilityLabel("Back")
            }
        }
#endif

        // Compact segmented view mode picker (macOS only)
#if os(macOS)
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
#endif

#if os(macOS)
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed)
        }
#endif

        // Upload actions
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("Upload Files…") { viewModel.presentFilePicker() }
#if os(iOS)
                Button("Upload from Photos…") { viewModel.showPhotoPicker = true }
#endif
#if os(macOS)
                Button("Upload Folder…") { viewModel.showFolderImporter = true }
#endif
                Divider()
                Button("New Folder…") { newFolderName = ""; showNewFolderSheet = true }
            } label: {
                Image(systemName: "plus")
            }
            .disabled(!viewModel.hasCredentials)
            .help("Upload")
        }

#if os(macOS)
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed)
        }

        // macOS: individual utility buttons
        ToolbarItemGroup(placement: .primaryAction) {
            Button { viewModel.loadCurrentFolder() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(!viewModel.hasCredentials)
            .help("Refresh")

            sortMenu
            selectionMenu
        }
#else
        // iOS: collapse refresh + sort + selection into a single "…" menu
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    viewModel.loadCurrentFolder()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(!viewModel.hasCredentials)

                Divider()

                Menu("Sort by…") {
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
                    Button {
                        viewModel.sortAscending.toggle()
                    } label: {
                        Label(viewModel.sortAscending ? "Ascending" : "Descending",
                              systemImage: viewModel.sortAscending ? "arrow.up" : "arrow.down")
                    }
                }

                Divider()

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
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .disabled(!viewModel.hasCredentials)
        }
#endif
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
                .font(.system(size: 28))
                .foregroundStyle(Color.accentColor)
            Text("New Folder")
                .font(.headline)
            TextField("Folder name", text: $newFolderName)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.secondary.opacity(0.12))
                )
#if os(macOS)
                .frame(width: 260)
#else
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
#endif
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
        .padding(26)
#if os(macOS)
        .frame(minWidth: 310)
#else
        .presentationDetents([.height(240)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .presentationBackground(.regularMaterial)
#endif
    }

    private func commitNewFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        showNewFolderSheet = false
        Task { await viewModel.createFolder(name: name) }
    }

    // MARK: - Helpers

    private func toggleSelection(_ item: R2Object) {
        if viewModel.selectedObjectIDs.contains(item.id) {
            viewModel.selectedObjectIDs.remove(item.id)
        } else {
            viewModel.selectedObjectIDs.insert(item.id)
        }
    }

#if os(macOS)
    private func navigateToFolderAnimated(_ object: R2Object) {
        viewModel.navigateToFolder(object)
    }

    private func navigateToSegmentAnimated(_ index: Int) {
        viewModel.navigateToSegment(index)
    }

    private func navigateToRootAnimated() {
        viewModel.navigateToRoot()
    }
#endif

#if os(iOS)
    private var isNavigatingFolders: Bool {
        viewModel.isBrowsing && (!viewModel.browserObjects.isEmpty || !viewModel.browserFolders.isEmpty)
    }

    private var folderNavigationTransition: AnyTransition {
        switch navigationAnimationDirection {
        case .forward:
            return .asymmetric(
                insertion: .move(edge: .trailing),
                removal: .move(edge: .leading)
            )
        case .back:
            return .asymmetric(
                insertion: .move(edge: .leading),
                removal: .move(edge: .trailing)
            )
        }
    }

    private func navigateToFolderAnimated(_ object: R2Object) {
        navigationAnimationDirection = .forward
        viewModel.navigateToFolder(object)
    }

    private func navigateBackAnimated() {
        navigationAnimationDirection = .back
        viewModel.navigateBack()
    }

    private func navigateToSegmentAnimated(_ index: Int) {
        navigationAnimationDirection = .back
        viewModel.navigateToSegment(index)
    }

    private func navigateToRootAnimated() {
        navigationAnimationDirection = .back
        viewModel.navigateToRoot()
    }

    private var edgeSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onChanged { value in
                let dx = value.translation.width
                let dy = value.translation.height

                // Match native iPhone behavior more closely: only begin from screen edges,
                // and only if the interaction is clearly horizontal.
                guard abs(dx) > abs(dy), abs(dx) > 6 else { return }

                let startsNearLeadingEdge = value.startLocation.x <= swipeActivationEdgeWidth

                if dx > 0, startsNearLeadingEdge, viewModel.canGoBack {
                    swipeDirection = .back
                    swipeOffset = min(dx * 0.45, 72)
                }
            }
            .onEnded { value in
                let dx = value.translation.width

                if swipeDirection == .back, dx > swipeThreshold {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        swipeOffset = 0
                    }
                    navigateBackAnimated()
                } else {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        swipeOffset = 0
                    }
                }

                swipeDirection = .none
            }
    }

    private func previewFile(_ object: R2Object) {
        guard !object.isFolder,
              !isPreparingPreview,
              let credentials = viewModel.credentials,
              let remoteURL = AWSV4Signer.presignedURL(for: object.key, credentials: credentials) else {
            return
        }

        previewLoadingName = object.name
        withAnimation(.easeInOut(duration: 0.2)) {
            isPreparingPreview = true
        }

        Task {
            do {
                let (tmpURL, _) = try await URLSession.shared.download(from: remoteURL)
                let previewURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(object.name)

                try? FileManager.default.removeItem(at: previewURL)
                try FileManager.default.moveItem(at: tmpURL, to: previewURL)

                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isPreparingPreview = false
                    }
                    deletePreviewFileIfNeeded()
                    previewItem = PreviewFile(url: previewURL)
                }
            } catch {
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isPreparingPreview = false
                    }
                    previewLoadingName = nil
                    viewModel.alertMessage = "Preview failed: \(error.localizedDescription)"
                    viewModel.showAlert = true
                }
            }
        }
    }

    private func deletePreviewFileIfNeeded() {
        guard let url = previewItem?.url else { return }
        try? FileManager.default.removeItem(at: url)
        previewItem = nil
        previewLoadingName = nil
    }

    private var previewLoadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Preparing preview…")
                    .font(.headline)
                if let previewLoadingName {
                    Text(previewLoadingName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .shadow(color: .black.opacity(0.12), radius: 16, x: 0, y: 8)
            .padding(.horizontal, 24)
        }
        .transition(.opacity)
    }

    private var folderLoadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.08)
                .ignoresSafeArea()

            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.regular)
                Text("Loading folder…")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.1), radius: 14, x: 0, y: 8)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }
#endif
}

// MARK: - Finder Icon Cell

struct FinderIconCell: View {
    let object: R2Object
    let credentials: R2Credentials
    let isSelected: Bool

    @State private var isHovered = false

#if os(iOS)
    private let thumbnailSize: CGFloat = 80
#else
    private let thumbnailSize: CGFloat = 72
#endif

    var body: some View {
        VStack(spacing: 6) {
            ThumbnailView(object: object, credentials: credentials, size: thumbnailSize)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2.5)
                )
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.05))
                )
#if os(macOS)
                .scaleEffect(isHovered && !isSelected ? 1.04 : 1.0)
#endif
                .overlay(alignment: .topTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.white, Color.accentColor)
                            .font(.system(size: 18))
                            .padding(4)
                            .transition(.scale.combined(with: .opacity))
                    }
                }

            Text(object.name)
                .font(.caption2)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(isSelected ? .primary : .secondary)
#if os(iOS)
                .frame(maxWidth: 100)
#else
                .frame(maxWidth: 120)
#endif
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
#if os(macOS)
        .onHover { isHovered = $0 }
#endif
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isSelected)
    }
}

// MARK: - R2Credentials convenience

extension R2Credentials {
    static let empty = R2Credentials(accountId: "", accessKeyId: "", secretAccessKey: "", bucketName: "")
}

// MARK: - iOS floating selection bar

#if os(iOS)
private struct PreviewFile: Identifiable {
    let id = UUID()
    let url: URL
}

private struct QuickLookPreviewSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {
        context.coordinator.url = url
        uiViewController.reloadData()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

struct IOSSelectionBar: View {
    @Environment(AppViewModel.self) private var viewModel
    @State private var showDeleteConfirm = false

    var body: some View {
        let sel = viewModel.selectedObjectIDs.count
        Group {
            if sel > 0 {
                HStack(spacing: 16) {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete (\(sel))", systemImage: "trash")
                            .font(.callout.weight(.semibold))
                    }
                    .foregroundStyle(.red)

                    Spacer()

                    Button {
                        withAnimation { viewModel.clearSelection() }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 12, x: 0, y: 4)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: sel > 0)
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
}
#endif

// MARK: - Photo picker helper (iOS only)

#if os(iOS)
extension BrowserView {
    /// Loads each PhotosPickerItem as Data, writes it to a temp file,
    /// then hands the resulting URLs to the view model's existing uploader.
    private func handleSelectedPhotos(_ items: [PhotosPickerItem]) {
        Task {
            var tempURLs: [URL] = []
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                let utType = item.supportedContentTypes.first
                let ext = utType.flatMap { UTType($0.identifier)?.preferredFilenameExtension } ?? "bin"
                let baseName = (item.itemIdentifier ?? UUID().uuidString)
                    .replacingOccurrences(of: "/", with: "_")
                let fileName = baseName.hasSuffix(".\(ext)") ? baseName : "\(baseName).\(ext)"
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(fileName)
                do {
                    try data.write(to: tempURL)
                    tempURLs.append(tempURL)
                } catch {
                    // Skip files we can't write
                }
            }
            if !tempURLs.isEmpty {
                await MainActor.run { viewModel.handleDroppedURLs(tempURLs) }
            }
        }
    }
}
#endif

#Preview {
    BrowserView()
        .environment(AppViewModel())
#if os(macOS)
        .frame(width: 860, height: 580)
#endif
}
