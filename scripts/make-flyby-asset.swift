import AppKit

// Prepare flyby artwork: turn a white-background PNG into transparent-background art and
// crop it to the visible content.
//
//   swift scripts/make-flyby-asset.swift <in.png> Tracki/Resources/flyby.png
//
// Source art usually arrives opaque with wide margins. Both break the flyby: its window is
// fully transparent (so an opaque background flies a white rectangle across the screen) and
// the margin eats into the fixed height budget (so the drawing renders small).
//
// The background is removed with an edge flood fill, NOT a global white key — a global key
// punches holes in white parts *inside* the drawing (lettering, cockpit windows). Edge pixels
// then get their alpha scaled by luminance, which removes the anti-aliased white fringe.
//
// Always check the result on a dark background: a fringe is invisible against a light
// desktop and obvious against a dark one.

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: make-flyby-asset <in.png> <out.png>\n".utf8))
    exit(2)
}
let inPath = CommandLine.arguments[1]
let outPath = CommandLine.arguments[2]

guard let src = NSImage(contentsOfFile: inPath),
      let srcCG = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("could not read \(inPath)\n".utf8)); exit(1)
}

let w = srcCG.width, h = srcCG.height
var px = [UInt8](repeating: 0, count: w * h * 4)
guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                          space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    FileHandle.standardError.write(Data("bitmap alloc failed\n".utf8)); exit(1)
}
ctx.draw(srcCG, in: CGRect(x: 0, y: 0, width: w, height: h))

// A pixel counts as background if it's near-white.
let threshold: UInt8 = 232
@inline(__always) func isBackground(_ i: Int) -> Bool {
    px[i] >= threshold && px[i + 1] >= threshold && px[i + 2] >= threshold
}

// Flood fill inward from every border pixel.
var transparent = [Bool](repeating: false, count: w * h)
var stack: [Int] = []
for x in 0..<w { stack.append(x); stack.append((h - 1) * w + x) }
for y in 0..<h { stack.append(y * w); stack.append(y * w + w - 1) }

while let p = stack.popLast() {
    if transparent[p] { continue }
    let i = p * 4
    guard isBackground(i) else { continue }
    transparent[p] = true
    let x = p % w, y = p / w
    if x > 0 { stack.append(p - 1) }
    if x < w - 1 { stack.append(p + 1) }
    if y > 0 { stack.append(p - w) }
    if y < h - 1 { stack.append(p + w) }
}

// Apply alpha. For surviving light pixels that touch the background, scale alpha by how
// dark they are — this eats the anti-aliased white halo around the line art.
var out = px
for p in 0..<(w * h) {
    let i = p * 4
    if transparent[p] {
        out[i] = 0; out[i + 1] = 0; out[i + 2] = 0; out[i + 3] = 0
        continue
    }
    let x = p % w, y = p / w
    var touchesBG = false
    for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
        let nx = x + dx, ny = y + dy
        if nx >= 0, nx < w, ny >= 0, ny < h, transparent[ny * w + nx] { touchesBG = true; break }
    }
    guard touchesBG else { continue }
    let lum = (Double(px[i]) * 0.299 + Double(px[i + 1]) * 0.587 + Double(px[i + 2]) * 0.114) / 255.0
    let alpha = max(0.0, min(1.0, (1.0 - lum) * 1.6))
    out[i + 3] = UInt8(alpha * 255)
    // Premultiplied: scale colour to match the new alpha.
    out[i] = UInt8(Double(px[i]) * alpha)
    out[i + 1] = UInt8(Double(px[i + 1]) * alpha)
    out[i + 2] = UInt8(Double(px[i + 2]) * alpha)
}

// Crop to the bounding box of anything visible.
var minX = w, maxX = -1, minY = h, maxY = -1
for y in 0..<h {
    for x in 0..<w where out[(y * w + x) * 4 + 3] > 8 {
        if x < minX { minX = x }
        if x > maxX { maxX = x }
        if y < minY { minY = y }
        if y > maxY { maxY = y }
    }
}
guard maxX >= minX, maxY >= minY else {
    FileHandle.standardError.write(Data("nothing visible after keying\n".utf8)); exit(1)
}

guard let outCtx = CGContext(data: &out, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                             space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
      let full = outCtx.makeImage(),
      let cropped = full.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)) else {
    FileHandle.standardError.write(Data("crop failed\n".utf8)); exit(1)
}

let rep = NSBitmapImageRep(cgImage: cropped)
guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("png encode failed\n".utf8)); exit(1)
}
try png.write(to: URL(fileURLWithPath: outPath))
print("\(w)x\(h) -> \(cropped.width)x\(cropped.height)  (cropped \(minX),\(minY))")
