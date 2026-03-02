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
    @State private var selection: SidebarDestination = .history
    @State private var bucketsExpanded = true
    @State private var utilitiesExpanded = true

    var body: some View {
        @Bindable var viewModel = viewModel

        NavigationSplitView {
            sidebarContent
                .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 240)
        } detail: {
            detailContent
                .navigationTitle("")
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
        .fileImporter(
            isPresented: $viewModel.showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls): viewModel.handleSelectedFiles(urls)
            case .failure(let error):
                viewModel.alertMessage = error.localizedDescription
                viewModel.showAlert = true
            }
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
        .alert("Error", isPresented: $viewModel.showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            if let msg = viewModel.alertMessage { Text(msg) }
        }
    }

    // MARK: - Sidebar

    private var sidebarContent: some View {
        List(selection: $selection) {
            Section(isExpanded: $bucketsExpanded) {
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

            Section(isExpanded: $utilitiesExpanded) {
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

    // MARK: - Detail

    @ViewBuilder
    private var detailContent: some View {
        switch selection {
        case .bucket(let id):
            BrowserView()
                .onAppear { viewModel.selectCredentials(id: id) }
        case .history:
            UploadHistoryView()
        case .settings:
            SettingsView()
        }
    }
}

#Preview {
    ContentView()
        .environment(AppViewModel())
}
