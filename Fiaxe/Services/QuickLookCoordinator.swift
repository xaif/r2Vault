#if os(macOS)
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
/// Streams the file directly from R2 via a presigned URL — no download required.
@MainActor
final class QuickLookCoordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {

    static let shared = QuickLookCoordinator()

    private var previewItem: PreviewItem? = nil

    private override init() { super.init() }

    /// Call this when the user presses spacebar or double-clicks a file.
    func preview(_ object: R2Object, credentials: R2Credentials) {
        let panel = QLPreviewPanel.shared()!

        // Toggle: if already visible for same coordinator, close it
        if panel.isVisible && panel.dataSource === self {
            panel.close()
            return
        }

        // Generate a presigned URL and pass it directly to Quick Look — no download needed.
        // previewItemTitle supplies the filename so QL picks the right previewer plugin.
        guard let presignedURL = AWSV4Signer.presignedURL(for: object.key, credentials: credentials) else { return }
        previewItem = PreviewItem(url: presignedURL, title: object.name)

        panel.dataSource = self
        panel.delegate  = self
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
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

#endif // os(macOS)
