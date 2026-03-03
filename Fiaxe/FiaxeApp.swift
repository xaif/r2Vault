import SwiftUI
import AppKit

@main
struct R2VaultApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var viewModel = AppViewModel()
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

// MARK: - App Delegate

/// Prevents the app from quitting when the main window is closed.
/// Combined with LSUIElement = YES in Info.plist, the app lives only
/// in the menu bar and never appears in the Dock or app switcher.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
