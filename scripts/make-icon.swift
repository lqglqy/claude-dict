// Draws the 1024px app icon: a blue-to-teal rounded square with 译 and a small spark.
// Usage: make-icon <output.png>
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "icon_1024.png"
let size = 1024
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else { fatalError("bitmap") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let canvas = CGFloat(size)
let tile = NSRect(x: 100, y: 100, width: canvas - 200, height: canvas - 200)
let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
shadow.shadowBlurRadius = 30
shadow.shadowOffset = NSSize(width: 0, height: -14)
NSGraphicsContext.saveGraphicsState()
shadow.set()
NSColor(srgbRed: 0.16, green: 0.38, blue: 0.86, alpha: 1).setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
shape.addClip()
let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.15, green: 0.33, blue: 0.86, alpha: 1),
    NSColor(srgbRed: 0.09, green: 0.62, blue: 0.70, alpha: 1),
])
gradient?.draw(in: tile, angle: -55)
NSGraphicsContext.restoreGraphicsState()

let glyphFont = NSFont(name: "PingFangSC-Semibold", size: 500) ?? NSFont.systemFont(ofSize: 500, weight: .bold)
let glyph = NSAttributedString(string: "译", attributes: [.font: glyphFont, .foregroundColor: NSColor.white])
let glyphSize = glyph.size()
glyph.draw(at: NSPoint(x: (canvas - glyphSize.width) / 2, y: (canvas - glyphSize.height) / 2 - 16))

let spark = NSAttributedString(string: "✦", attributes: [
    .font: NSFont.systemFont(ofSize: 160, weight: .bold),
    .foregroundColor: NSColor(srgbRed: 1, green: 0.83, blue: 0.36, alpha: 1),
])
spark.draw(at: NSPoint(x: tile.maxX - 220, y: tile.maxY - 230))

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
try png.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
