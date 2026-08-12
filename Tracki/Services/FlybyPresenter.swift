import AppKit
import SwiftUI

/// The passive on-screen reminder: artwork that flies across the top of the screen and
/// leaves. Click-through and non-activating by design — it must never steal focus from what
/// the user is doing, which is the whole point of a menu-bar time tracker.
@MainActor
enum FlybyPresenter {
    /// Seconds the artwork takes to cross the screen. A slow drift is deliberate — it should
    /// read as ambient, not as an alert demanding attention.
    static let travelDuration: TimeInterval = 12.0
    /// Rendered height of the artwork, in points.
    fileprivate static let artworkHeight: CGFloat = 132
    /// How far below the top of the usable screen area the flyby drifts, as a fraction of
    /// that area's height. 0 = tucked under the menu bar.
    private static let verticalDropFraction: CGFloat = 0.20

    /// Only one flyby at a time — a second reminder replaces the one in flight.
    private static var inFlight: NSWindow?

    static func show(title: String, subtitle: String) {
        guard let screen = NSScreen.main else { return }

        inFlight?.close()

        let hosting = NSHostingView(rootView: FlybyCard(title: title, subtitle: subtitle))
        let size = hosting.fittingSize
        hosting.frame = CGRect(origin: .zero, size: size)

        // Fly across the upper part of the usable area. The artwork faces left, so it
        // travels right-to-left.
        let visible = screen.visibleFrame
        let y = visible.maxY - size.height - 8 - (visible.height * verticalDropFraction)
        let start = CGRect(x: visible.maxX + 8, y: y, width: size.width, height: size.height)
        let end = CGRect(x: visible.minX - size.width - 8, y: y, width: size.width, height: size.height)

        let window = NSWindow(contentRect: start, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        // Above normal windows and full-screen apps, and visible on every Space.
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.alphaValue = 0

        // `orderFrontRegardless` (not makeKeyAndOrderFront) keeps the current app in focus.
        window.orderFrontRegardless()
        inFlight = window

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.4
            window.animator().alphaValue = 1
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = travelDuration
            context.timingFunction = CAMediaTimingFunction(name: .linear)
            window.animator().setFrame(end, display: true)
        }, completionHandler: {
            MainActor.assumeIsolated {
                window.close()
                if inFlight === window { inFlight = nil }
            }
        })
    }
}

/// Loads the flyby artwork, newest-wins across two locations.
///
/// **ASSET DROP POINTS** — the app looks for `flyby.png` (or `.gif`/`.jpg`) in:
///  1. `~/Library/Application Support/Tracki/flyby.png` — a live override. Drop a file here
///     and the next flyby uses it, no rebuild. Best for iterating on the art.
///  2. The app bundle's `Resources/` — the shipped default. Add the file to
///     `Tracki/Resources/` in the repo; `make bundle` copies it in.
///
/// With neither present the flyby falls back to a plain text card, so the reminder still
/// works before any artwork lands.
enum FlybyAsset {
    private static let basename = "flyby"
    private static let extensions = ["png", "gif", "jpg", "jpeg", "pdf"]

    static var overrideDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Tracki", isDirectory: true)
    }

    static func load() -> NSImage? {
        if let dir = overrideDirectory {
            for ext in extensions {
                let url = dir.appendingPathComponent("\(basename).\(ext)")
                if FileManager.default.fileExists(atPath: url.path),
                   let image = NSImage(contentsOf: url) {
                    return image
                }
            }
        }
        for ext in extensions {
            if let url = Bundle.main.url(forResource: basename, withExtension: ext),
               let image = NSImage(contentsOf: url) {
                return image
            }
        }
        return nil
    }
}

/// The flyby's visual: the artwork, with the elapsed time in a small pill beneath it.
private struct FlybyCard: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 6) {
            if let artwork = FlybyAsset.load() {
                Image(nsImage: artwork)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(height: FlybyPresenter.artworkHeight)
            } else {
                placeholder
            }

            caption
        }
        .padding(20) // room for the shadow inside the window bounds
        .fixedSize()
    }

    /// Shown until artwork is dropped in — see `FlybyAsset`.
    private var placeholder: some View {
        Image(systemName: "stopwatch")
            .font(.system(size: 44))
            .foregroundStyle(.white)
            .frame(width: 88, height: 88)
            .background(Circle().fill(Color.black.opacity(0.82)))
    }

    private var caption: some View {
        VStack(spacing: 1) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: 300)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.82))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
    }
}
