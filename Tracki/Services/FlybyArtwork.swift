import AppKit

/// Loading, importing and preparing the artwork that `FlybyPresenter` flies across the screen.
///
/// Artwork resolves newest-wins across two locations:
///  1. `~/Library/Application Support/Tracki/flyby.png` — the user's own image, set from
///     Settings (or dropped in by hand). Wins over the shipped default.
///  2. The app bundle's `Resources/` — the default that ships with Tracki.
///
/// With neither present the flyby falls back to a plain text card, so reminders still work.
enum FlybyArtwork {
    private static let basename = "flyby"
    /// Extensions accepted for a hand-dropped file. Imports always normalise to `.png`.
    private static let extensions = ["png", "gif", "jpg", "jpeg", "pdf", "heic", "tiff", "webp"]

    /// Longest side an imported image is scaled down to. The flyby renders ~132pt tall, so
    /// this is generous even on Retina, and it keeps background removal fast on huge photos.
    private static let maxImportDimension = 1024

    enum ImportError: LocalizedError {
        case unreadable
        case processingFailed
        case noDirectory

        var errorDescription: String? {
            switch self {
            case .unreadable: return "That file couldn't be read as an image."
            case .processingFailed: return "That image couldn't be prepared for the flyby."
            case .noDirectory: return "Couldn't find the Application Support folder."
            }
        }
    }

    // MARK: - Locations

    static var overrideDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Tracki", isDirectory: true)
    }

    /// The user's own artwork, if they've set one.
    static var customImageURL: URL? {
        guard let dir = overrideDirectory else { return nil }
        for ext in extensions {
            let url = dir.appendingPathComponent("\(basename).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    static var hasCustomImage: Bool { customImageURL != nil }

    // MARK: - Load

    static func load() -> NSImage? {
        if let url = customImageURL, let image = NSImage(contentsOf: url) { return image }
        for ext in extensions {
            if let url = Bundle.main.url(forResource: basename, withExtension: ext),
               let image = NSImage(contentsOf: url) {
                return image
            }
        }
        return nil
    }

    // MARK: - Import

    /// Copy `url` in as the user's flyby artwork, normalised to PNG.
    ///
    /// `removeBackground` runs the same edge flood fill the shipped asset was prepared with:
    /// source art is usually opaque with wide margins, and both break the flyby — its window
    /// is transparent (so an opaque image flies as a rectangle) and the margin eats the fixed
    /// height budget (so the drawing renders small). Cropping to content happens either way.
    static func importImage(from url: URL, removeBackground: Bool) throws {
        guard let dir = overrideDirectory else { throw ImportError.noDirectory }
        guard let image = NSImage(contentsOf: url),
              let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ImportError.unreadable
        }

        let scaled = downscaled(source)
        guard let prepared = prepare(scaled, removeBackground: removeBackground),
              let png = pngData(prepared) else {
            throw ImportError.processingFailed
        }

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Clear any other extension first so the lookup above stays unambiguous.
        try removeCustomImage()
        try png.write(to: dir.appendingPathComponent("\(basename).png"), options: .atomic)
    }

    /// Drop the user's artwork and fall back to the shipped default.
    static func removeCustomImage() throws {
        guard let dir = overrideDirectory else { return }
        for ext in extensions {
            let url = dir.appendingPathComponent("\(basename).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Processing

    private static func downscaled(_ image: CGImage) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxImportDimension else { return image }
        let scale = Double(maxImportDimension) / Double(longest)
        let w = max(1, Int(Double(image.width) * scale))
        let h = max(1, Int(Double(image.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return image
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    /// Optionally key out the contiguous background, then crop to whatever is still visible.
    ///
    /// The pixel buffer is allocated explicitly rather than via `Array.withUnsafeMutableBytes`
    /// because the `CGContext` has to outlive the access — a pointer borrowed from an Array is
    /// only valid inside the closure. `makeImage()` copies, so freeing afterwards is safe.
    private static func prepare(_ image: CGImage, removeBackground: Bool) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }

        let count = w * h * 4
        let px = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        px.initialize(repeating: 0, count: count)
        defer { px.deallocate() }

        guard let ctx = CGContext(data: px, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        let buffer = UnsafeMutableBufferPointer(start: px, count: count)
        if removeBackground {
            keyOutBackground(buffer, width: w, height: h)
        }

        guard let full = ctx.makeImage() else { return nil }
        guard let bounds = contentBounds(buffer, width: w, height: h) else { return full }
        return full.cropping(to: bounds) ?? full
    }

    /// A pixel counts as background only if it's near-white.
    private static let backgroundThreshold: UInt8 = 232

    /// Flood fill inward from the border. Deliberately NOT a global white key — that would
    /// punch holes in white parts *inside* the drawing (lettering, windows, highlights).
    private static func keyOutBackground(_ px: UnsafeMutableBufferPointer<UInt8>, width w: Int, height h: Int) {
        @inline(__always) func isBackground(_ i: Int) -> Bool {
            px[i] >= backgroundThreshold && px[i + 1] >= backgroundThreshold && px[i + 2] >= backgroundThreshold
        }

        var transparent = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        stack.reserveCapacity(w * 2 + h * 2)
        for x in 0..<w { stack.append(x); stack.append((h - 1) * w + x) }
        for y in 0..<h { stack.append(y * w); stack.append(y * w + w - 1) }

        while let p = stack.popLast() {
            if transparent[p] { continue }
            guard isBackground(p * 4) else { continue }
            transparent[p] = true
            let x = p % w, y = p / w
            if x > 0 { stack.append(p - 1) }
            if x < w - 1 { stack.append(p + 1) }
            if y > 0 { stack.append(p - w) }
            if y < h - 1 { stack.append(p + w) }
        }

        let original = Array(px)
        for p in 0..<(w * h) {
            let i = p * 4
            if transparent[p] {
                px[i] = 0; px[i + 1] = 0; px[i + 2] = 0; px[i + 3] = 0
                continue
            }
            // Surviving light pixels that touch the background get their alpha scaled by
            // darkness, which eats the anti-aliased white fringe around the art.
            let x = p % w, y = p / w
            var touchesBackground = false
            for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                let nx = x + dx, ny = y + dy
                if nx >= 0, nx < w, ny >= 0, ny < h, transparent[ny * w + nx] {
                    touchesBackground = true
                    break
                }
            }
            guard touchesBackground else { continue }
            let lum = (Double(original[i]) * 0.299 + Double(original[i + 1]) * 0.587
                       + Double(original[i + 2]) * 0.114) / 255.0
            let alpha = max(0.0, min(1.0, (1.0 - lum) * 1.6))
            px[i + 3] = UInt8(alpha * 255)
            px[i] = UInt8(Double(original[i]) * alpha)
            px[i + 1] = UInt8(Double(original[i + 1]) * alpha)
            px[i + 2] = UInt8(Double(original[i + 2]) * alpha)
        }
    }

    /// Bounding box of everything still visible, or nil if the image keyed away entirely
    /// (an all-white source, say) — in which case the caller keeps the uncropped image
    /// rather than returning an empty picture.
    private static func contentBounds(_ px: UnsafeMutableBufferPointer<UInt8>, width w: Int, height h: Int) -> CGRect? {
        var minX = w, maxX = -1, minY = h, maxY = -1
        for y in 0..<h {
            for x in 0..<w where px[(y * w + x) * 4 + 3] > 8 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private static func pngData(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
