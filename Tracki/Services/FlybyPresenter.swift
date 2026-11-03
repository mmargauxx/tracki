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
        inFlight = nil

        // Render the card to a bitmap once, then let Core Animation slide that bitmap. The
        // old approach animated the *window frame*, which AppKit steps from a CPU timer and
        // re-lays out the SwiftUI view on every step — visibly jittery, and the off-screen
        // start/end positions put the window on a neighbouring display.
        let scale = screen.backingScaleFactor
        let renderer = ImageRenderer(content: FlybyCard(title: title, subtitle: subtitle))
        renderer.scale = scale
        guard let image = renderer.cgImage else { return }
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)

        // A stationary strip across the usable width of this screen. The card travels inside
        // it, so it's clipped at the screen edges and never leaks onto another monitor.
        // The artwork faces left, so it travels right-to-left.
        let visible = screen.visibleFrame
        let y = visible.maxY - size.height - 8 - (visible.height * verticalDropFraction)
        let strip = CGRect(x: visible.minX, y: y, width: visible.width, height: size.height)

        let window = NSWindow(contentRect: strip, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        // Above normal windows and full-screen apps, and visible on every Space.
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let container = NSView(frame: CGRect(origin: .zero, size: strip.size))
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        window.contentView = container

        let card = CALayer()
        card.contents = image
        card.contentsScale = scale
        card.bounds = CGRect(origin: .zero, size: size)
        card.anchorPoint = .zero
        let startX = strip.width
        let endX = -size.width
        card.position = CGPoint(x: endX, y: 0) // model value = final state; no snap-back
        container.layer?.addSublayer(card)

        // `orderFrontRegardless` (not makeKeyAndOrderFront) keeps the current app in focus.
        window.orderFrontRegardless()
        inFlight = window

        CATransaction.begin()
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                window.close()
                if inFlight === window { inFlight = nil }
            }
        }

        let travel = CABasicAnimation(keyPath: "position.x")
        travel.fromValue = startX
        travel.toValue = endX
        travel.duration = travelDuration
        travel.timingFunction = CAMediaTimingFunction(name: .linear)
        card.add(travel, forKey: "travel")

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.4
        card.add(fade, forKey: "fade")

        CATransaction.commit()
    }
}

/// The flyby's visual: the artwork, with the elapsed time in a small pill beneath it.
/// Artwork loading and import live in `FlybyArtwork`.
private struct FlybyCard: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 6) {
            if let artwork = FlybyArtwork.load() {
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

    /// Shown until artwork is dropped in — see `FlybyArtwork`.
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
