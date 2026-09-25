#!/usr/bin/env swift
// Renders Design/AppIcon/Pincer.svg into Apps/Shared/Assets.xcassets/AppIcon.appiconset.
// Usage: swift scripts/make-icons.swift
// iOS gets the full-bleed 1024px artwork (the system applies the mask). macOS gets the artwork
// clipped to Apple's icon grid (824pt rounded rect on a 1024pt canvas) with a drop shadow.
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let source = root.appendingPathComponent("Design/AppIcon/Pincer.svg")
let output = root.appendingPathComponent("Apps/Shared/Assets.xcassets/AppIcon.appiconset")

guard let artwork = NSImage(contentsOf: source) else { fatalError("Could not load \(source.path)") }

func render(pixels: Int, _ draw: (CGContext, CGFloat) -> Void) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    draw(context.cgContext, CGFloat(pixels) / 1024)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func iosIcon() -> Data {
    render(pixels: 1024) { _, _ in
        artwork.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024))
    }
}

func macIcon(pixels: Int) -> Data {
    render(pixels: pixels) { cg, scale in
        let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
        let shape = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
        cg.scaleBy(x: scale, y: scale)
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 20, color: NSColor.black.withAlphaComponent(0.3).cgColor)
        cg.addPath(shape)
        cg.setFillColor(NSColor.black.cgColor)
        cg.fillPath()
        cg.restoreGState()
        cg.addPath(shape)
        cg.clip()
        artwork.draw(in: rect)
    }
}

let fm = FileManager.default
try? fm.removeItem(at: output)
try fm.createDirectory(at: output, withIntermediateDirectories: true)

var images: [[String: String]] = [
    ["filename": "ios-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"],
]
try iosIcon().write(to: output.appendingPathComponent("ios-1024.png"))

// File names follow iconutil's .iconset convention so scripts/bundle-mac.sh can reuse them.
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try macIcon(pixels: points * scale).write(to: output.appendingPathComponent(name))
        images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
    }
}

func writeJSON(_ object: Any, to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url)
}
let info = ["author": "xcode", "version": 1] as [String: Any]
try writeJSON(["images": images, "info": info], to: output.appendingPathComponent("Contents.json"))
try writeJSON(["info": info], to: output.deletingLastPathComponent().appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icons to \(output.path)")
