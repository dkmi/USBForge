import AppKit
import Foundation

// Original vector artwork rendered into the standard macOS AppIcon sizes.
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let asset = root.appendingPathComponent("Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: asset, withIntermediateDirectories: true)
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
let background = NSBezierPath(roundedRect: NSRect(x: 70, y: 70, width: 884, height: 884), xRadius: 198, yRadius: 198)
NSGradient(starting: NSColor(calibratedRed: 0.08, green: 0.19, blue: 0.31, alpha: 1), ending: NSColor(calibratedRed: 0.02, green: 0.07, blue: 0.15, alpha: 1))!.draw(in: background, angle: -90)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.35); shadow.shadowBlurRadius = 24; shadow.shadowOffset = NSSize(width: 0, height: -15); shadow.set()
let body = NSBezierPath(roundedRect: NSRect(x: 334, y: 220, width: 356, height: 460), xRadius: 78, yRadius: 78)
NSGradient(starting: NSColor(calibratedRed: 0.24, green: 0.94, blue: 0.85, alpha: 1), ending: NSColor(calibratedRed: 0.02, green: 0.58, blue: 0.75, alpha: 1))!.draw(in: body, angle: -90)
NSGraphicsContext.restoreGraphicsState()
let connector = NSBezierPath(roundedRect: NSRect(x: 398, y: 665, width: 228, height: 145), xRadius: 22, yRadius: 22)
NSGradient(starting: NSColor.white, ending: NSColor(calibratedWhite: 0.68, alpha: 1))!.draw(in: connector, angle: -90)
NSColor(calibratedRed: 0.08, green: 0.15, blue: 0.23, alpha: 1).setFill()
for x in [436, 542] { NSBezierPath(roundedRect: NSRect(x: x, y: 717, width: 46, height: 48), xRadius: 5, yRadius: 5).fill() }
// Bold write arrow remains recognizable at small Dock sizes.
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 486, y: 594)); arrow.line(to: NSPoint(x: 538, y: 594))
arrow.line(to: NSPoint(x: 538, y: 458)); arrow.line(to: NSPoint(x: 589, y: 458))
arrow.line(to: NSPoint(x: 512, y: 372)); arrow.line(to: NSPoint(x: 435, y: 458))
arrow.line(to: NSPoint(x: 486, y: 458)); arrow.close()
NSColor.white.setFill(); arrow.fill()
NSColor(calibratedRed: 0.03, green: 0.32, blue: 0.43, alpha: 0.55).setFill()
NSBezierPath(roundedRect: NSRect(x: 450, y: 285, width: 124, height: 14), xRadius: 7, yRadius: 7).fill()
image.unlockFocus()
var entries: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: asset.appendingPathComponent(name))
        entries.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
try JSONSerialization.data(withJSONObject: ["images": entries, "info": ["author": "xcode", "version": 1]], options: [.prettyPrinted, .sortedKeys]).write(to: asset.appendingPathComponent("Contents.json"))
try JSONSerialization.data(withJSONObject: ["info": ["author": "xcode", "version": 1]], options: [.prettyPrinted]).write(to: root.appendingPathComponent("Assets.xcassets/Contents.json"))
