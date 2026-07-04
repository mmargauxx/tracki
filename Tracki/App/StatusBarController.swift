import AppKit
import SwiftUI

@MainActor
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let viewModel: TimerViewModel

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
        popover.contentViewController = NSHostingController(rootView: RootView(viewModel: viewModel))

        // Status bar title: " HH:MM:SS" while a timer runs, icon only when idle.
        viewModel.onStatusChange = { [weak self] text in
            self?.statusItem.button?.title = text.map { " " + $0 } ?? ""
        }

        viewModel.onAppearLoad()
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else if let button = statusItem.button {
            viewModel.popoverOpened()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
