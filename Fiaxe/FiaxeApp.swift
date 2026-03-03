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
                Button("Check for Updates") {
                    viewModel.checkForUpdates(userInitiated: true)
                }
                .disabled(viewModel.updateStatus.isChecking)
            }
        }

        Settings {
            SettingsView()
                .environment(viewModel)
        }
    }
}
