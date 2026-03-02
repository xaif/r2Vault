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

        Settings {
            SettingsView()
                .environment(viewModel)
        }
    }
}
