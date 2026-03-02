import AppKit
import Quartz

/// Wraps a URL as a QLPreviewItem (URL is a struct, can't directly conform to NSObject protocol)
private final class PreviewItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?

    init(url: URL, title: String) {
        self.previewItemURL = url
        self.previewItemTitle = title
    }
}

/// Manages the system Quick Look panel (spacebar / double-click preview).
/// Downloads the file to a temp location, then presents QLPreviewPanel.
@MainActor
final class QuickLookCoordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {

    static let shared = QuickLookCoordinator()

    private var previewItem: PreviewItem? = nil
    private var downloadTask: Task<Void, Never>? = nil

    private override init() { super.init() }

    /// Call this when the user presses spacebar or double-clicks a file.
    func preview(_ object: R2Object, credentials: R2Credentials) {
        // Cancel any previous download
        downloadTask?.cancel()
        previewItem = nil

        let panel = QLPreviewPanel.shared()!

        // Toggle: if already visible for same coordinator, close it
        if panel.isVisible && panel.dataSource === self {
            panel.close()
            return
        }

        panel.dataSource = self
        panel.delegate  = self
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()

        // Download file to a named temp file
        downloadTask = Task {
            guard let presignedURL = AWSV4Signer.presignedURL(for: object.key, credentials: credentials) else { return }
            do {
                let (tmpURL, _) = try await URLSession.shared.download(from: presignedURL)
                // Move to a stable path with the real filename so QL picks the right previewer
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent("fiaxe_ql_\(object.name)")
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmpURL, to: dest)

                guard !Task.isCancelled else { return }
                self.previewItem = PreviewItem(url: dest, title: object.name)
                QLPreviewPanel.shared()?.reloadData()
            } catch {
                // ignore — panel stays empty if download fails
            }
        }
    }

    // MARK: - QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewItem != nil ? 1 : 0
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewItem
    }

    // MARK: - QLPreviewPanelDelegate

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        false
    }
}
