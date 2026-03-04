import SwiftUI

struct UpdateSheetView: View {
    @Environment(AppViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss

#if os(macOS)
    private var updater: AppUpdater { AppUpdater.shared }
#endif

    var body: some View {
        @Bindable var viewModel = viewModel

        VStack(spacing: 20) {
            switch viewModel.updateStatus {
            case .upToDate:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)
                Text("You're up to date")
                    .font(.title2.bold())
                Text("R2 Vault is already running the latest version.")
                    .foregroundStyle(.secondary)
                Button("OK") { dismiss() }
                    .buttonStyle(.borderedProminent)

            case .available(let release):
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.accentColor)
                Text("Update Available")
                    .font(.title2.bold())
                Text("Version \(release.tagName) is ready to install.")
                    .foregroundStyle(.secondary)

#if os(macOS)
                switch updater.state {
                case .idle, .failed:
                    if case .failed(let msg) = updater.state {
                        Text("Failed: \(msg)")
                            .foregroundStyle(.red)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                    }
                    if let reason = updater.updateBlockReason {
                        Text(reason)
                            .foregroundStyle(.orange)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                    }
                    HStack(spacing: 12) {
                        Button("Not Now") { dismiss() }
                        Button(updater.state.isFailed ? "Retry Download" : "Download Update") {
                            updater.download(release: release)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!updater.canSelfUpdate)
                    }
                case .downloading(let progress):
                    VStack(spacing: 8) {
                        ProgressView(value: progress)
                            .frame(width: 240)
                        Text("Downloading… \(Int(progress * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Cancel") { updater.cancel() }
                        .foregroundStyle(.red)
                case .downloaded:
                    Text("Update downloaded. Install when you're ready.")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Button("Later") { dismiss() }
                        Button("Install Now") { updater.installDownloaded() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!updater.canSelfUpdate)
                    }
                case .installing:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Installing…")
                            .foregroundStyle(.secondary)
                    }
                }
#else
                // On iOS, updates are delivered through the App Store
                Text("Update available on the App Store.")
                    .foregroundStyle(.secondary)
                Button("OK") { dismiss() }
                    .buttonStyle(.borderedProminent)
#endif

            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.orange)
                Text("Update Check Failed")
                    .font(.title2.bold())
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    Button("OK") { dismiss() }
                    Button("Try Again") { viewModel.checkForUpdates(userInitiated: true) }
                        .buttonStyle(.borderedProminent)
                }

            default:
                ProgressView()
                Text("Checking for updates…")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(32)
#if os(macOS)
        .frame(width: 360)
#endif
    }
}
