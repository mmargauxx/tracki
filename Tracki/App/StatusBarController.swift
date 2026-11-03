import AppKit
import SwiftUI

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let viewModel: TimerViewModel
    /// When the popover last closed. A transient popover closes on the mouse-down of a click
    /// on the status item, and the button's action then fires — without this the popover
    /// would immediately reopen instead of toggling shut.
    private var lastClose: Date = .distantPast

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        viewModel = TimerViewModel()
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "stopwatch", accessibilityDescription: "Tracki")
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        let hosting = NSHostingController(rootView: RootView(viewModel: viewModel))
        // Drive the popover's size from SwiftUI's ideal size, so it tracks screen switches
        // and the error disclosure instead of lagging a layout pass behind.
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting

        // Status bar title: " HH:MM:SS" while a timer runs, icon only when idle.
        viewModel.onStatusChange = { [weak self] text in
            let title = text.map { " " + $0 } ?? ""
            // Skip no-op writes — each one re-lays out the status bar.
            if self?.statusItem.button?.title != title {
                self?.statusItem.button?.title = title
            }
        }

        viewModel.onAppearLoad()
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        guard Date().timeIntervalSince(lastClose) > 0.25, let button = statusItem.button else { return }

        // Capture the frontmost app before we activate ourselves — the PR-title lookup
        // prefers whichever browser the user was just looking at.
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        // Activate first so the popover comes up as the key window and the text field
        // takes typing straight away.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()

        // The browser lookup runs AppleScript synchronously; do it after the popover is on
        // screen so opening never feels laggy.
        DispatchQueue.main.async { [viewModel] in
            viewModel.popoverOpened(frontmostBundleID: frontmost)
        }
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated { lastClose = Date() }
    }
}
