import AppKit
import Foundation

let output = URL(fileURLWithPath: "AstraApp/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let baseSize = 1024
let base = NSImage(size: NSSize(width: baseSize, height: baseSize))
base.lockFocus()

let rect = NSRect(x: 0, y: 0, width: baseSize, height: baseSize)
NSColor(calibratedRed: 0.025, green: 0.11, blue: 0.13, alpha: 1).setFill()
rect.fill()

let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.00, green: 0.62, blue: 0.60, alpha: 1),
    NSColor(calibratedRed: 0.10, green: 0.29, blue: 0.48, alpha: 1),
    NSColor(calibratedRed: 0.35, green: 0.18, blue: 0.60, alpha: 1)
])!
gradient.draw(in: rect, angle: 35)

let markRect = NSRect(x: 184, y: 180, width: 656, height: 664)
let mark = NSBezierPath(roundedRect: markRect, xRadius: 108, yRadius: 108)
NSColor(calibratedWhite: 0.98, alpha: 0.94).setFill()
mark.fill()

let inner = NSBezierPath(roundedRect: markRect.insetBy(dx: 42, dy: 42), xRadius: 72, yRadius: 72)
NSColor(calibratedRed: 0.03, green: 0.14, blue: 0.17, alpha: 1).setFill()
inner.fill()

let rackStroke = NSBezierPath()
rackStroke.lineWidth = 34
rackStroke.lineCapStyle = .round
NSColor(calibratedWhite: 0.97, alpha: 1).setStroke()

for index in 0..<3 {
    let y = 342 + index * 132
    let server = NSBezierPath(roundedRect: NSRect(x: 304, y: y, width: 416, height: 70), xRadius: 28, yRadius: 28)
    server.lineWidth = 28
    server.stroke()

    let dot = NSBezierPath(ovalIn: NSRect(x: 624, y: y + 22, width: 26, height: 26))
    NSColor(calibratedRed: 0.00, green: 0.86, blue: 0.70, alpha: 1).setFill()
    dot.fill()
}

rackStroke.move(to: NSPoint(x: 512, y: 250))
rackStroke.line(to: NSPoint(x: 512, y: 306))
rackStroke.move(to: NSPoint(x: 382, y: 250))
rackStroke.line(to: NSPoint(x: 642, y: 250))
rackStroke.stroke()

let letter = "A" as NSString
let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 170, weight: .black),
    .foregroundColor: NSColor(calibratedRed: 0.00, green: 0.88, blue: 0.73, alpha: 1),
    .kern: -8
]
let letterSize = letter.size(withAttributes: attributes)
letter.draw(
    at: NSPoint(x: (CGFloat(baseSize) - letterSize.width) / 2, y: 690),
    withAttributes: attributes
)

base.unlockFocus()

func pngData(for image: NSImage, size: Int) throws -> Data {
    guard
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
    else {
        throw CocoaError(.fileWriteUnknown)
    }

    bitmap.size = NSSize(width: size, height: size)
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw CocoaError(.fileWriteUnknown)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return png
}

let icons: [(String, Int)] = [
    ("Icon-20@2x.png", 40),
    ("Icon-20@3x.png", 60),
    ("Icon-29@2x.png", 58),
    ("Icon-29@3x.png", 87),
    ("Icon-40@2x.png", 80),
    ("Icon-40@3x.png", 120),
    ("Icon-60@2x.png", 120),
    ("Icon-60@3x.png", 180),
    ("Icon-1024.png", 1024)
]

for (filename, size) in icons {
    let data = try pngData(for: base, size: size)
    try data.write(to: output.appendingPathComponent(filename), options: .atomic)
}

print("Generated \(icons.count) Astra app icons")
