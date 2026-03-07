import SwiftUI
import UniformTypeIdentifiers

// MARK: - Sidebar Navigation Model

enum SidebarDestination: Hashable {
    case bucket(UUID)
    case history
    case dashboard
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
                case .success(let urls):
                    Task { @MainActor in
                        viewModel.handleSelectedFolders(urls)
                    }
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
                Label("Dashboard", systemImage: "chart.bar.xaxis.ascending")
                    .tag(SidebarDestination.dashboard)
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
        case .dashboard:
            DashboardView()
                .navigationTitle("Dashboard")
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

    private var iOSLayout: some View {
        return TabView(selection: $selectedTab) {
            // Dashboard Tab
            Tab("Dashboard", systemImage: "chart.bar.xaxis.ascending", value: IOSTab.dashboard) {
                NavigationStack {
                    DashboardView()
                        .navigationTitle("Dashboard")
                        .navigationBarTitleDisplayMode(.large)
                }
            }

            // Browser Tab
            Tab("Files", systemImage: "folder.fill", value: IOSTab.browser) {
                iOSBrowserStack
            }

            // Settings Tab
            Tab("Settings", systemImage: "gearshape.fill", value: IOSTab.settings) {
                NavigationStack {
                    SettingsView()
                        .navigationTitle("Settings")
                        .navigationBarTitleDisplayMode(.large)
                }
            }

            Tab(value: IOSTab.search, role: .search) {
                iOSSearchStack
            }
        }
        .tabViewSearchActivation(.searchTabSelection)
    }

    private var iOSBrowserStack: some View {
        NavigationStack(path: $browserPath) {
            iOSBrowserContent
        }
    }

    private var iOSSearchStack: some View {
        NavigationStack {
            iOSSearchContent
        }
    }

    @ViewBuilder
    private var iOSBrowserContent: some View {
        @Bindable var viewModel = viewModel
        iOSBrowserTab
        .navigationTitle(iOSBrowserTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: String.self) { folderKey in
            BrowserView()
                .navigationTitle(folderKey
                    .split(separator: "/", omittingEmptySubsequences: true)
                    .last.map(String.init) ?? folderKey)
                .navigationBarTitleDisplayMode(.inline)
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                UploadHUDView()
                    .environment(viewModel)
                    .padding(.horizontal, 12)

                IOSSelectionBar()
                    .environment(viewModel)
            }
            .padding(.bottom, 8)
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
            BrowserView()
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

    private var iOSBrowserTitle: String {
        if let last = viewModel.pathSegments.last {
            return last
        }
        return viewModel.credentials?.bucketName ?? "R2 Vault"
    }

    @ViewBuilder
    private var iOSSearchContent: some View {
        @Bindable var viewModel = viewModel
        iOSBrowserTab
            .searchable(
                text: $viewModel.filterText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search files"
            )
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    UploadHUDView()
                        .environment(viewModel)
                        .padding(.horizontal, 12)

                    IOSSelectionBar()
                        .environment(viewModel)
                }
                .padding(.bottom, 8)
            }
    }
#endif
}

// MARK: - iOS Tab Model

#if os(iOS)
enum IOSTab: Hashable {
    case browser, dashboard, settings, search
}
#endif

#Preview {
    ContentView()
        .environment(AppViewModel())
}
