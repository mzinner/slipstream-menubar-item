#!/usr/bin/env swift
// Draws the app icon: the bolt from Slipstream's web UI (and the menu bar item),
// `M13.5 2 5 13h6l-.5 9L19 11h-6z` in a 24-unit box, as a white outline on a
// rounded indigo-to-violet square, and writes each pixel size macOS needs into an
// .icns (91 KB).
//
//   swift scripts/make-icon.swift Resources/AppIcon.icns [preview.png]

import AppKit

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write("usage: make-icon.swift <out.icns> [preview.png]\n".data(using: .utf8)!)
    exit(2)
}
let output = URL(fileURLWithPath: arguments[1])

/// The icon at `side` pixels, following the macOS icon grid: an 824/1024 tile
/// centred on the canvas, with the bolt filling about 60% of the tile's height.
func icon(side: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(side) / 1024

    let tile = NSRect(x: 100, y: 100, width: 824, height: 824).applying(.init(scaleX: scale, y: scale))
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * scale, yRadius: 185 * scale)
    // A vertical gradient drawn one flat row at a time. NSGradient dithers, and that
    // noise made the 1024 px PNG five times larger (162 KB instead of 32 KB).
    let bottom = NSColor(srgbRed: 0.29, green: 0.16, blue: 0.62, alpha: 1)  // violet
    let top = NSColor(srgbRed: 0.09, green: 0.10, blue: 0.27, alpha: 1)     // indigo
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    let rows = Int(tile.height.rounded(.up))
    for row in 0..<rows {
        bottom.blended(withFraction: CGFloat(row) / CGFloat(max(rows - 1, 1)), of: top)!.setFill()
        NSRect(x: tile.minX, y: tile.minY + CGFloat(row), width: tile.width, height: 1).fill()
    }
    NSGraphicsContext.restoreGraphicsState()

    // The bolt's outline spans x 5…19 and y 2…22 of its 24-unit box.
    let unit = 26.0 * scale
    let origin = NSPoint(x: 512 * scale - 12 * unit, y: 512 * scale - 12 * unit)
    func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: origin.x + x * unit, y: origin.y + (24 - y) * unit)  // SVG y runs down
    }
    let bolt = NSBezierPath()
    bolt.move(to: point(13.5, 2))
    bolt.line(to: point(5, 13))
    bolt.line(to: point(11, 13))
    bolt.line(to: point(10.5, 22))
    bolt.line(to: point(19, 11))
    bolt.line(to: point(13, 11))
    bolt.close()
    bolt.lineWidth = 1.8 * unit
    bolt.lineJoinStyle = .round
    bolt.lineCapStyle = .round
    // No glow: a blurred halo gives every pixel around the bolt its own colour,
    // which roughly doubled the icon's size (189 KB with it, 91 KB without).
    bolt.lineWidth = 1.8 * unit
    NSColor.white.setStroke()
    bolt.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
// Each pixel size once: 16@2x, 128@2x and 256@2x would repeat the 32, 256 and
// 512 px images, and macOS scales the 1x ones for those slots.
let slots = [("16x16", 16), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
             ("256x256", 256), ("512x512", 512), ("512x512@2x", 1024)]
for (name, side) in slots {
    let png = icon(side: side).representation(using: .png, properties: [:])!
    try png.write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
if arguments.count >= 3 {
    try icon(side: 1024).representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: arguments[2]))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
exit(iconutil.terminationStatus)
