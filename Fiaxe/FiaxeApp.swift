import SwiftUI

@main
struct R2VaultApp: App {
    @State private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(viewModel)
        }
        .defaultSize(width: 800, height: 560)
        .commands {
            CommandGroup(after: .appInfo) {
                switch viewModel.updateStatus {
                case .idle, .failed, .upToDate:
                    Button(viewModel.updateStatus.isChecking ? "Checking for Updates…" : "Check for Updates") {
                        viewModel.checkForUpdates()
                    }
                    .disabled(viewModel.updateStatus.isChecking)
                case .checking:
                    Button("Checking for Updates…") { }
                        .disabled(true)
                case .available(let release):
                    switch viewModel.updaterState {
                    case .idle, .failed:
                        Button("Install Update \(release.tagName)") {
                            AppUpdater.shared.onStateChange = { viewModel.updaterState = AppUpdater.shared.state }
                            AppUpdater.shared.install(release: release)
                        }
                    case .downloading(let progress):
                        Button("Downloading… \(Int(progress * 100))%") { }
                            .disabled(true)
                        Button("Cancel Download") {
                            AppUpdater.shared.cancel()
                        }
                    case .installing:
                        Button("Installing Update…") { }
                            .disabled(true)
                    }
                }
            }
        }

        Settings {
            SettingsView()
                .environment(viewModel)
        }
    }
}
