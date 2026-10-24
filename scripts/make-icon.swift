// Renders Resources/AppIcon.icns: a dark rounded square with a notch and a four-slot wheel.
// Usage: swift scripts/make-icon.swift   (needs only the Command Line Tools)
import AppKit

let accent = NSColor(srgbRed: 0.04, green: 0.52, blue: 1.0, alpha: 1)

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: size / 1024, y: size / 1024)

    // macOS icon grid: 824 pt shape centered on a 1024 canvas.
    let shape = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shapePath = NSBezierPath(roundedRect: shape, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSColor.black.setFill()
    shapePath.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shapePath.addClip()
    NSGradient(colors: [
        NSColor(srgbRed: 0.20, green: 0.21, blue: 0.24, alpha: 1),
        NSColor(srgbRed: 0.07, green: 0.07, blue: 0.09, alpha: 1),
    ])!.draw(in: shape, angle: -90)

    // The notch hanging from the top edge.
    let notch = NSBezierPath(roundedRect: CGRect(x: 512 - 150, y: 924 - 82, width: 300, height: 120), xRadius: 40, yRadius: 40)
    NSColor.black.setFill()
    notch.fill()

    // The wheel: four ring segments with gaps, the top one highlighted.
    let center = CGPoint(x: 512, y: 450)
    let outer: CGFloat = 270
    let inner: CGFloat = 120
    let gap: CGFloat = 7  // degrees
    for index in 0..<4 {
        let mid = 90 - Double(index) * 90  // top, right, bottom, left (counterclockwise math angles)
        let start = CGFloat(mid - 45 + gap)
        let end = CGFloat(mid + 45 - gap)
        let segment = NSBezierPath()
        segment.appendArc(withCenter: center, radius: outer, startAngle: start, endAngle: end, clockwise: false)
        segment.appendArc(withCenter: center, radius: inner, startAngle: end, endAngle: start, clockwise: true)
        segment.close()
        if index == 0 {
            NSGradient(colors: [accent.blended(withFraction: 0.25, of: .white)!, accent])!
                .draw(in: segment, angle: -90)
        } else {
            NSColor.white.withAlphaComponent(0.14).setFill()
            segment.fill()
        }
    }
    // Hub.
    NSColor.white.withAlphaComponent(0.9).setFill()
    NSBezierPath(ovalIn: CGRect(x: center.x - 34, y: center.y - 34, width: 68, height: 68)).fill()

    NSGraphicsContext.restoreGraphicsState()

    // Hairline edge.
    NSColor.white.withAlphaComponent(0.12).setStroke()
    shapePath.lineWidth = 3
    shapePath.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let data = drawIcon(size: pixels).representation(using: .png, properties: [:])!
        try data.write(to: iconset.appendingPathComponent(name))
    }
}
try drawIcon(size: 1024).representation(using: .png, properties: [:])!
    .write(to: root.appendingPathComponent("Resources/AppIcon-1024.png"))

let output = root.appendingPathComponent("Resources/AppIcon.icns")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try process.run()
process.waitUntilExit()
print(process.terminationStatus == 0 ? "Wrote \(output.path)" : "iconutil failed")
