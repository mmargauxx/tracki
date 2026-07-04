import SwiftUI

/// Renders the timer popover with sample data to a PNG — used for README/marketing shots
/// via `Tracki --screenshot <path>`. Never runs during normal launch.
@MainActor
enum ScreenshotRenderer {
    static func render(to path: String) {
        let vm = TimerViewModel()
        vm.connectionState = .connected
        vm.screen = .timer
        vm.clients = [
            TogglClient(id: 1, name: "Acme Co"),
            TogglClient(id: 2, name: "Personal"),
        ]
        vm.projects = [
            TogglProject(id: 10, workspaceId: 1, clientId: 1, name: "Website Redesign", color: "#E0296B", active: true),
            TogglProject(id: 11, workspaceId: 1, clientId: 1, name: "API Platform", color: "#4BB543", active: true),
            TogglProject(id: 12, workspaceId: 1, clientId: 2, name: "Side Project", color: "#3B82F6", active: true),
        ]
        vm.selectedClientId = 1
        vm.selectedProjectId = 10
        vm.timerDescription = "Fix login flow · PR #482"
        vm.elapsedText = "00:12:34"
        vm.runningEntry = TimeEntry(
            id: 123, workspaceId: 1, projectId: 10,
            description: "Fix login flow · PR #482", start: Date(), duration: -1
        )

        // ImageRenderer can't draw AppKit-backed controls (text field, pickers, button), so
        // render the real view hierarchy inside an offscreen window and cacheDisplay it.
        NSApp.appearance = NSAppearance(named: .aqua)

        let card = TimerView(viewModel: vm)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.18), radius: 24, x: 0, y: 12)
            .padding(48)

        let hosting = NSHostingController(rootView: card)
        let size = hosting.view.fittingSize
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentViewController = hosting
        window.setContentSize(size)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.displayIfNeeded()

        // Give AppKit a couple of runloop turns to fully lay out the controls, then capture.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let content = window.contentView else { NSApp.terminate(nil); return }
            window.makeFirstResponder(nil) // drop focus so the text field shows no selection highlight
            content.layoutSubtreeIfNeeded()
            content.displayIfNeeded()
            guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
                FileHandle.standardError.write(Data("bitmap alloc failed\n".utf8)); exit(1)
            }
            content.cacheDisplay(in: content.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                FileHandle.standardError.write(Data("png encode failed\n".utf8)); exit(1)
            }
            do {
                try png.write(to: URL(fileURLWithPath: path))
                print("Wrote \(path)")
            } catch {
                FileHandle.standardError.write(Data("write failed: \(error)\n".utf8)); exit(1)
            }
            NSApp.terminate(nil)
        }
    }
}
