import AppKit

// Renders Tracki's app icon at every size an .iconset needs. Pure CoreGraphics, no assets.
// Usage: swift scripts/make-icon.swift <output.iconset dir>

func drawIcon(pixels S: CGFloat) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: S, height: S)

    NSGraphicsContext.saveGraphicsState()
    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gctx
    let cg = gctx.cgContext
    cg.clear(CGRect(x: 0, y: 0, width: S, height: S))

    // Rounded-square (squircle) tile with a small transparent margin.
    let m = 0.085 * S
    let tile = CGRect(x: m, y: m, width: S - 2 * m, height: S - 2 * m)
    let radius = 0.2237 * (S - 2 * m)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

    cg.saveGState()
    cg.addPath(tilePath)
    cg.clip()
    let colors = [
        NSColor(srgbRed: 1.00, green: 0.39, blue: 0.57, alpha: 1).cgColor, // top  #FF6392
        NSColor(srgbRed: 0.83, green: 0.13, blue: 0.40, alpha: 1).cgColor  // bot  #D42166
    ] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    cg.drawLinearGradient(grad, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])
    cg.restoreGState()

    // Stopwatch glyph — white strokes.
    cg.setStrokeColor(NSColor.white.cgColor)
    cg.setFillColor(NSColor.white.cgColor)
    cg.setLineCap(.round)
    cg.setLineJoin(.round)

    let cx = S / 2
    let cy = 0.455 * S
    let R = 0.245 * S
    let sw = 0.052 * S

    // Face ring.
    cg.setLineWidth(sw)
    cg.addArc(center: CGPoint(x: cx, y: cy), radius: R, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    cg.strokePath()

    // Top button (crown).
    let stemW = 0.11 * S
    let stemH = 0.072 * S
    let stemRect = CGRect(x: cx - stemW / 2, y: cy + R + sw * 0.15, width: stemW, height: stemH)
    cg.addPath(CGPath(roundedRect: stemRect, cornerWidth: stemH * 0.4, cornerHeight: stemH * 0.4, transform: nil))
    cg.fillPath()

    // Two angled start/stop nubs.
    func nub(_ angle: CGFloat) {
        let inner = R + sw * 0.15
        let outer = R + sw * 1.25
        cg.setLineWidth(sw * 0.9)
        cg.move(to: CGPoint(x: cx + cos(angle) * inner, y: cy + sin(angle) * inner))
        cg.addLine(to: CGPoint(x: cx + cos(angle) * outer, y: cy + sin(angle) * outer))
        cg.strokePath()
    }
    nub(.pi * 0.75) // top-left
    nub(.pi * 0.25) // top-right

    // Hand pointing to ~1 o'clock, plus a center pivot dot.
    cg.setLineWidth(sw)
    let handLen = R * 0.66
    let ha = .pi / 2 - .pi * 0.16
    cg.move(to: CGPoint(x: cx, y: cy))
    cg.addLine(to: CGPoint(x: cx + cos(ha) * handLen, y: cy + sin(ha) * handLen))
    cg.strokePath()

    cg.addArc(center: CGPoint(x: cx, y: cy), radius: sw * 0.72, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    cg.fillPath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write("usage: make-icon.swift <out.iconset>\n".data(using: .utf8)!)
    exit(1)
}
let outDir = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// (pixel size, iconset filenames)
let entries: [(CGFloat, [String])] = [
    (16,   ["icon_16x16.png"]),
    (32,   ["icon_16x16@2x.png", "icon_32x32.png"]),
    (64,   ["icon_32x32@2x.png"]),
    (128,  ["icon_128x128.png"]),
    (256,  ["icon_128x128@2x.png", "icon_256x256.png"]),
    (512,  ["icon_256x256@2x.png", "icon_512x512.png"]),
    (1024, ["icon_512x512@2x.png"]),
]

for (size, names) in entries {
    let png = drawIcon(pixels: size)
    for name in names {
        try! png.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
    }
}
print("Wrote iconset to \(outDir)")
