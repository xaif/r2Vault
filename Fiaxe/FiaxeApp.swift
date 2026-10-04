import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@main
struct R2VaultApp: App {
#if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
#else
    @UIApplicationDelegateAdaptor(IOSAppDelegate.self) var appDelegate
#endif
    @State private var viewModel: AppViewModel
#if os(macOS)
    // MenuBarManager is created eagerly so the menu bar icon appears immediately on launch,
    // regardless of whether the main window has been opened yet.
    @State private var menuBarManager: MenuBarManager
#endif

    init() {
        let vm = AppViewModel()
        _viewModel = State(initialValue: vm)
#if os(macOS)
        _menuBarManager = State(initialValue: MenuBarManager(viewModel: vm))
#endif
    }

    var body: some Scene {
#if os(macOS)
        WindowGroup(id: "main") {
            ContentView()
                .environment(viewModel)
                .accentColor(Color(red: 0xF8/255, green: 0x69/255, blue: 0x36/255))
                .withOpenWindowHandler(viewModel: viewModel)
        }
        .defaultSize(width: 800, height: 560)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About R2 Vault") {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.sendAction(#selector(NSApplication.orderFrontStandardAboutPanel(_:)), to: nil, from: nil)
                }
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    viewModel.checkForUpdates(userInitiated: true)
                }
                .disabled(viewModel.updateStatus.isChecking)
                Divider()
            }
            // ⌘Q closes the windows but keeps the app alive in the menu bar.
            // Quitting for real goes through the menu bar's Quit button.
            CommandGroup(replacing: .appTermination) {
                Button("Close to Menu Bar") {
                    appDelegate.closeToMenuBar()
                }
                .keyboardShortcut("q")
                Button("Quit R2 Vault") {
                    NSApp.terminate(nil)
                }
            }
            CommandGroup(replacing: .help) {
                Button("Welcome to R2 Vault") {
                    viewModel.presentOnboarding()
                    viewModel.showMainWindow()
                }
                .disabled(viewModel.showOnboarding)
                Link("R2 Vault on GitHub", destination: URL(string: "https://github.com/xaif/r2Vault")!)
            }
        }

        Settings {
            SettingsView()
                .environment(viewModel)
        }
#else
        WindowGroup {
            ContentView()
                .environment(viewModel)
                .accentColor(Color(red: 0xF8/255, green: 0x69/255, blue: 0x36/255))
        }
#endif
    }
}

#if os(iOS)
final class IOSAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        BackgroundDownloadService.shared.handleBackgroundEvents(completionHandler: completionHandler)
    }
}
#endif

// MARK: - Open Window Handler (macOS only)

#if os(macOS)
/// Captures the SwiftUI openWindow environment action and registers it with the view model
/// so non-SwiftUI code (MenuBarManager, MenuBarView) can reopen the main window.
private struct OpenWindowHandlerModifier: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    let viewModel: AppViewModel

    func body(content: Content) -> some View {
        content.onAppear {
            viewModel.openMainWindow = { openWindow(id: "main") }
        }
    }
}

private extension View {
    func withOpenWindowHandler(viewModel: AppViewModel) -> some View {
        modifier(OpenWindowHandlerModifier(viewModel: viewModel))
    }
}

// MARK: - App Delegate

/// Prevents the app from quitting when the main window is closed,
/// so it can continue living in the menu bar.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    /// Closes every app window (main, Settings) and hides the app so focus returns
    /// to the previous app, leaving only the menu bar icon running.
    func closeToMenuBar() {
        for window in NSApp.windows where
            window.isVisible &&
            !(window is NSPanel) &&
            window.styleMask.contains(.titled) &&
            !window.className.contains("StatusBar") &&
            !window.className.contains("Popover") {
            window.close()
        }
        NSApp.hide(nil)
    }
}
#endif
