#if os(macOS)
import AppKit
import SwiftUI

/// Fills the popover — including the arrow/notch — with a solid, appearance-adaptive
/// background so menu-bar content renders consistently in both light and dark mode.
/// Mirrors BucketDrop's approach; `windowBackgroundColor` resolves per the current
/// appearance, replacing the fragile makeKey()-only desaturation workaround.
private final class PopoverBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.set()
        dirtyRect.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Manages a persistent NSStatusItem + NSPopover for the menu bar widget.
/// Using NSPopover with .applicationDefined behavior means it never auto-dismisses
/// when the app loses focus — only a click on the status bar icon closes it.
@MainActor
final class MenuBarManager: NSObject {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var backgroundView: PopoverBackgroundView?
    private let viewModel: AppViewModel

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        super.init()
        // Defer status item creation until the app has a window server
        // connection; creating it during App.init() causes a
        // CGSConnectionByID assertion crash on macOS 15.6+.
        DispatchQueue.main.async { [self] in
            setupStatusItem()
            setupPopover()
        }
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "square.and.arrow.up",
                                   accessibilityDescription: "R2 Vault")
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 440)
        // .applicationDefined = popover stays open when app loses focus
        popover.behavior = .applicationDefined
        popover.animates = true

        let hostingController = NSHostingController(
            rootView: MenuBarView()
                .environment(viewModel)
        )
        popover.contentViewController = hostingController
    }

    // MARK: - Toggle

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            guard let button = statusItem.button else { return }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            // Force the popover window to appear active so colors never desaturate, then
            // back the whole popover (content + arrow/notch) with a solid, appearance-adaptive
            // color so light/dark mode always renders correctly. The window is attached
            // synchronously after show(), the same way BucketDrop fixes NSPopover theming.
            let popoverWindow = popover.contentViewController?.view.window
            popoverWindow?.makeKey()
            if let frameView = popoverWindow?.contentView?.superview {
                if backgroundView == nil || backgroundView?.superview == nil {
                    let bg = PopoverBackgroundView(frame: frameView.bounds)
                    bg.autoresizingMask = [.width, .height]
                    frameView.addSubview(bg, positioned: .below, relativeTo: nil)
                    backgroundView = bg
                }
            }
        }
    }
}

#endif // os(macOS)
