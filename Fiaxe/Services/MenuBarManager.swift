import AppKit
import SwiftUI

/// Manages a persistent NSStatusItem + NSPopover for the menu bar widget.
/// Using NSPopover with .applicationDefined behavior means it never auto-dismisses
/// when the app loses focus — only a click on the status bar icon closes it.
@MainActor
final class MenuBarManager: NSObject {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let viewModel: AppViewModel

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        super.init()
        setupStatusItem()
        setupPopover()

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
            // Force the popover window to always appear active so colors never desaturate.
            // Dispatched async so the window is fully attached before makeKey() is called.
            DispatchQueue.main.async {
                self.popover.contentViewController?.view.window?.makeKey()
            }
        }
    }
}
