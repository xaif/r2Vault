import SwiftUI
import UniformTypeIdentifiers

// MARK: - Sidebar Navigation Model

enum SidebarDestination: Hashable {
    case bucket(UUID)
    case history
    case settings
}

struct ContentView: View {
    @Environment(AppViewModel.self) private var viewModel

    var body: some View {
        @Bindable var viewModel = viewModel

#if os(macOS)
        macOSLayout
            .alert("Error", isPresented: $viewModel.showAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                if let msg = viewModel.alertMessage { Text(msg) }
            }
            .sheet(isPresented: $viewModel.showUpdateSheet) {
                UpdateSheetView()
                    .environment(viewModel)
            }
            .fileImporter(
                isPresented: $viewModel.showFolderImporter,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls): viewModel.handleSelectedFolders(urls)
                case .failure(let error):
                    viewModel.alertMessage = error.localizedDescription
                    viewModel.showAlert = true
                }
            }
#else
        iOSLayout
            .alert("Error", isPresented: $viewModel.showAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                if let msg = viewModel.alertMessage { Text(msg) }
            }
            .sheet(isPresented: $viewModel.showUpdateSheet) {
                UpdateSheetView()
                    .environment(viewModel)
            }
#endif
    }

#if os(macOS)
    // MARK: - macOS Layout

    @State private var selection: SidebarDestination = .history
    @State private var bucketsExpanded = true
    @State private var utilitiesExpanded = true

    private var macOSLayout: some View {
        @Bindable var viewModel = viewModel

        return NavigationSplitView {
            sidebarContent
                .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 240)
        } detail: {
            detailContent
                .overlay(alignment: .bottomTrailing) {
                    UploadHUDView()
                        .padding(16)
                }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 820, minHeight: 520)
        .onAppear {
            if case .bucket = selection { return }
            if let first = viewModel.credentialsList.first {
                selection = .bucket(first.id)
            }
        }
        .onChange(of: viewModel.credentialsList.map(\.id)) { _, ids in
            guard case .bucket(let currentId) = selection else { return }
            if !ids.contains(currentId), let first = ids.first {
                selection = .bucket(first)
            }
        }
    }

    private var sidebarContent: some View {
        List(selection: Binding(
            get: { selection },
            set: { if let v = $0 { selection = v } }
        )) {
            Section(isExpanded: Binding(
                get: { bucketsExpanded },
                set: { bucketsExpanded = $0 }
            )) {
                if viewModel.credentialsList.isEmpty {
                    Label("No buckets configured", systemImage: "externaldrive")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(viewModel.credentialsList) { creds in
                        Label(creds.bucketName, systemImage: "externaldrive.fill")
                            .tag(SidebarDestination.bucket(creds.id))
                    }
                }
            } header: {
                Text("Buckets")
            }

            Section(isExpanded: Binding(
                get: { utilitiesExpanded },
                set: { utilitiesExpanded = $0 }
            )) {
                Label("History", systemImage: "clock")
                    .tag(SidebarDestination.history)
                Label("Settings", systemImage: "gearshape")
                    .tag(SidebarDestination.settings)
            } header: {
                Text("Utilities")
            }
        }
        .listStyle(.sidebar)
        .animation(.easeInOut(duration: 0.2), value: viewModel.credentialsList.count)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selection {
        case .bucket(let id):
            BrowserView()
                .id(id)
                .onAppear { viewModel.selectCredentials(id: id) }
                .onChange(of: id) { _, newID in viewModel.selectCredentials(id: newID) }
                .navigationTitle(macOSBrowserTitle)
        case .history:
            UploadHistoryView()
                .navigationTitle("History")
        case .settings:
            SettingsView()
                .navigationTitle("Settings")
        }
    }

    /// Builds the macOS toolbar title: shows the deepest path segment, falling back to the bucket name.
    private var macOSBrowserTitle: String {
        if let last = viewModel.pathSegments.last { return last }
        return viewModel.credentials?.bucketName ?? "R2 Vault"
    }

#else
    // MARK: - iOS Layout

    @State private var selectedTab: IOSTab = .browser
    @State private var browserPath: [String] = []
    @State private var isSearchPresented = false

    private var iOSLayout: some View {
        return TabView(selection: $selectedTab) {
            // Browser Tab — shows a bucket picker if multiple buckets are configured
            Tab("Files", systemImage: "folder.fill", value: IOSTab.browser) {
                iOSBrowserStack
            }

            // History Tab
            Tab("History", systemImage: "clock.fill", value: IOSTab.history) {
                NavigationStack {
                    UploadHistoryView()
                        .navigationTitle("History")
                        .navigationBarTitleDisplayMode(.large)
                }
            }

            // Settings Tab
            Tab("Settings", systemImage: "gearshape.fill", value: IOSTab.settings) {
                NavigationStack {
                    SettingsView()
                        .navigationTitle("Settings")
                        .navigationBarTitleDisplayMode(.large)
                }
            }
        }
    }

    private var iOSBrowserStack: some View {
        @Bindable var viewModel = viewModel

        return NavigationStack(path: $browserPath) {
            Group {
                if isSearchPresented || !viewModel.filterText.isEmpty {
                    iOSBrowserTab
                        .searchable(
                            text: $viewModel.filterText,
                            isPresented: $isSearchPresented,
                            placement: .navigationBarDrawer(displayMode: .automatic),
                            prompt: "Search"
                        )
                } else {
                    iOSBrowserTab
                }
            }
            .navigationTitle(viewModel.credentials?.bucketName ?? "R2 Vault")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { folderKey in
                BrowserView(folderPrefix: folderKey)
                    .navigationTitle(folderKey
                        .split(separator: "/", omittingEmptySubsequences: true)
                        .last.map(String.init) ?? folderKey)
                    .navigationBarTitleDisplayMode(.inline)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isSearchPresented = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("Search")
                }
            }
            .overlay(alignment: .bottom) {
                IOSSelectionBar()
                    .environment(viewModel)
            }
            .onChange(of: viewModel.filterText) { _, newValue in
                if newValue.isEmpty {
                    isSearchPresented = false
                }
            }
        }
    }

    @ViewBuilder
    private var iOSBrowserTab: some View {
        if viewModel.credentialsList.isEmpty {
            // No credentials — show a helpful empty state with a button to Settings
            ContentUnavailableView {
                Label("No Buckets", systemImage: "externaldrive.badge.questionmark")
            } description: {
                Text("Add your Cloudflare R2 credentials to get started.")
            } actions: {
                Button("Add Credentials") {
                    selectedTab = .settings
                }
                .buttonStyle(.borderedProminent)
            }
        } else if viewModel.credentialsList.count == 1 {
            BrowserView(folderPrefix: "")
        } else {
            // Multiple buckets: show a list to pick from, then push into BrowserView
            List(viewModel.credentialsList) { creds in
                NavigationLink(value: "") {
                    Label(creds.bucketName, systemImage: "externaldrive.fill")
                }
                .simultaneousGesture(TapGesture().onEnded {
                    viewModel.selectCredentials(id: creds.id)
                })
            }
            .listStyle(.insetGrouped)
        }
    }
#endif
}

// MARK: - iOS Tab Model

#if os(iOS)
enum IOSTab: Hashable {
    case browser, history, settings
}
#endif

#Preview {
    ContentView()
        .environment(AppViewModel())
}
