import UIKit
import SwiftUI
import UniformTypeIdentifiers

/// Entry point for the R2 Vault Share Extension.
/// Reads shared files/images from the incoming NSExtensionContext, copies them
/// into the shared App Group container, then saves a pending-upload record so
/// the host app can pick it up on next launch (or via openURL).
class ShareViewController: UIViewController {

    // MARK: - View lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        let shareView = ShareView { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        } onCancel: { [weak self] in
            self?.extensionContext?.cancelRequest(withError: ShareError.cancelled)
        }
        let host = UIHostingController(rootView: shareView)
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)

        // Kick off the file extraction immediately
        Task {
            await extractAndQueue()
        }
    }

    // MARK: - File extraction

    private func extractAndQueue() async {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else { return }

        let appGroupID = "group.fiaxe.r2Vault"
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else { return }

        let inboxURL = containerURL.appendingPathComponent("ShareInbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)

        var copiedURLs: [URL] = []

        for item in items {
            guard let attachments = item.attachments else { continue }
            for provider in attachments {
                if let url = await loadFileURL(from: provider) {
                    let dest = inboxURL.appendingPathComponent(url.lastPathComponent)
                    // Remove stale file if present
                    try? FileManager.default.removeItem(at: dest)
                    do {
                        try FileManager.default.copyItem(at: url, to: dest)
                        copiedURLs.append(dest)
                    } catch {
                        // Skip files we can't copy
                    }
                }
            }
        }

        // Persist the list of pending URLs to UserDefaults (shared suite)
        if !copiedURLs.isEmpty {
            let defaults = UserDefaults(suiteName: appGroupID)
            var pending = defaults?.stringArray(forKey: "pendingShareURLs") ?? []
            pending.append(contentsOf: copiedURLs.map(\.absoluteString))
            defaults?.set(pending, forKey: "pendingShareURLs")
        }

        // Tell the host app to open so it processes the queue
        if let url = URL(string: "r2vault://share-inbox") {
            // openURL is not available in extensions; use the completion callback approach instead
            _ = url
        }

        // Complete the extension request
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// Attempts to load a file-backed URL from an NSItemProvider.
    private func loadFileURL(from provider: NSItemProvider) async -> URL? {
        // Priority: load as a file URL first (works for Files app, etc.)
        let fileTypes: [UTType] = [.image, .movie, .data, .fileURL]
        for type in fileTypes {
            if provider.hasItemConformingToTypeIdentifier(type.identifier) {
                if let url = try? await provider.loadItem(forTypeIdentifier: type.identifier) as? URL {
                    return url
                }
                // Some providers give Data instead of URL
                if let data = try? await provider.loadItem(forTypeIdentifier: type.identifier) as? Data {
                    let ext = type.preferredFilenameExtension ?? "bin"
                    let tempURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension(ext)
                    try? data.write(to: tempURL)
                    return tempURL
                }
            }
        }
        return nil
    }
}

// MARK: - SwiftUI overlay (progress / status)

private struct ShareView: View {
    let onDone: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "arrow.up.to.line.circle.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.orange)
                Text("Sending to R2 Vault…")
                    .font(.headline)
                Text("Files will be uploaded the next time you open R2 Vault.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
            .navigationTitle("R2 Vault")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Errors

private enum ShareError: Error {
    case cancelled
}
