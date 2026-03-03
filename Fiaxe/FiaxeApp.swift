import SwiftUI

@main
struct R2VaultApp: App {
    @State private var viewModel = AppViewModel()
    // Held as a stored property so it lives for the app's lifetime
    @State private var menuBarManager: MenuBarManager?

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(viewModel)
                .onAppear {
                    if menuBarManager == nil {
                        menuBarManager = MenuBarManager(viewModel: viewModel)
                    }
                }
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
