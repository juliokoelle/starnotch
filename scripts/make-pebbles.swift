// Draws the default character pack, "Pebbles": round, soft figures with two eyes, one sprite per
// state, in five colours. Pure Core Graphics, no source images, so the pack is ours to publish.
//
//   swift scripts/make-pebbles.swift Resources/Characters/pebbles.notchpack
import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    print("usage: swift scripts/make-pebbles.swift <output.notchpack>")
    exit(1)
}
let output = URL(fileURLWithPath: arguments[1])
let fm = FileManager.default
try? fm.removeItem(at: output)
try fm.createDirectory(at: output, withIntermediateDirectories: true)

struct Pebble {
    var id: String
    var name: String
    var color: NSColor
}

let pebbles = [
    Pebble(id: "pebble", name: "Pebble", color: NSColor(srgbRed: 0.50, green: 0.66, blue: 1.00, alpha: 1)),
    Pebble(id: "moss", name: "Moss", color: NSColor(srgbRed: 0.49, green: 0.80, blue: 0.60, alpha: 1)),
    Pebble(id: "ember", name: "Ember", color: NSColor(srgbRed: 0.95, green: 0.65, blue: 0.40, alpha: 1)),
    Pebble(id: "plum", name: "Plum", color: NSColor(srgbRed: 0.69, green: 0.55, blue: 0.94, alpha: 1)),
    Pebble(id: "slate", name: "Slate", color: NSColor(srgbRed: 0.66, green: 0.71, blue: 0.78, alpha: 1)),
]

enum Eyes { case open, focused, up, down, wide, closed, happy, sad }

struct Pose {
    var state: String
    var eyes: Eyes
    var squash: CGFloat = 1        // < 1: lower and wider
    var tilt: CGFloat = 0          // degrees
    var mouth: Mouth = .none
    var headphones = false
    var sparkles = false
    var dots = false               // typing
    var bubble = false             // thinking
    var dim = false                // sleepy: a little greyer
}

enum Mouth { case none, smile, frown, open }

let poses = [
    Pose(state: "idle", eyes: .open),
    Pose(state: "sleepy", eyes: .closed, squash: 0.94, dim: true),
    Pose(state: "working", eyes: .focused, mouth: .none),
    Pose(state: "thinking", eyes: .up, tilt: -6, bubble: true),
    Pose(state: "reply_typing", eyes: .down, dots: true),
    Pose(state: "curious", eyes: .wide, tilt: 7, mouth: .open),
    Pose(state: "sad", eyes: .sad, squash: 0.95, mouth: .frown),
    Pose(state: "celebrating", eyes: .happy, mouth: .smile, sparkles: true),
    Pose(state: "music", eyes: .happy, tilt: -5, headphones: true),
    Pose(state: "voice_listening", eyes: .open, headphones: true),
]

let size = CGSize(width: 240, height: 240)

func blend(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
    let a = a.usingColorSpace(.sRGB)!, b = b.usingColorSpace(.sRGB)!
    return NSColor(srgbRed: a.redComponent + (b.redComponent - a.redComponent) * t,
                   green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
                   blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t, alpha: 1)
}

func render(_ pebble: Pebble, _ pose: Pose) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let cg = NSGraphicsContext.current!.cgContext
    cg.setShouldAntialias(true)

    var base = pebble.color
    if pose.dim { base = blend(base, NSColor(srgbRed: 0.55, green: 0.57, blue: 0.62, alpha: 1), 0.35) }

    // Body: a pebble, a little wider than tall, sitting on the bottom edge.
    let width: CGFloat = 196 / max(pose.squash, 0.8) * (pose.squash < 1 ? 1.0 : 1.0)
    let height: CGFloat = 176 * pose.squash
    let body = CGRect(x: (size.width - width) / 2, y: 0, width: width, height: height)

    cg.saveGState()
    cg.translateBy(x: size.width / 2, y: 0)
    cg.rotate(by: pose.tilt * .pi / 180)
    cg.translateBy(x: -size.width / 2, y: 0)

    // Headphone band behind the head.
    if pose.headphones {
        let band = NSBezierPath()
        band.appendArc(withCenter: CGPoint(x: body.midX, y: body.midY + 4), radius: width * 0.47,
                       startAngle: 10, endAngle: 170)
        band.lineWidth = 11
        NSColor(srgbRed: 0.16, green: 0.17, blue: 0.2, alpha: 1).setStroke()
        band.stroke()
    }

    let shape = CGPath(ellipseIn: body, transform: nil)
    cg.addPath(shape)
    cg.clip()
    let colors = [blend(base, .white, 0.5).cgColor, base.cgColor, blend(base, .black, 0.38).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.5, 1])!
    let light = CGPoint(x: body.minX + body.width * 0.34, y: body.minY + body.height * 0.74)
    cg.drawRadialGradient(gradient, startCenter: light, startRadius: 0, endCenter: light,
                          endRadius: max(body.width, body.height) * 0.86, options: [.drawsAfterEndLocation])
    // Soft light along the top edge.
    let rim = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                         colors: [NSColor.white.withAlphaComponent(0.4).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                         locations: [0, 1])!
    cg.saveGState()
    cg.addPath(CGPath(ellipseIn: body, transform: nil))
    cg.addPath(CGPath(ellipseIn: body.insetBy(dx: 5, dy: 5).offsetBy(dx: 0, dy: -3), transform: nil))
    cg.clip(using: .evenOdd)
    cg.drawLinearGradient(rim, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.midY), options: [])
    cg.restoreGState()
    cg.resetClip()

    // Face.
    let ink = NSColor(srgbRed: 0.07, green: 0.07, blue: 0.09, alpha: 0.9)
    ink.setFill()
    ink.setStroke()
    let eyeY = body.minY + body.height * 0.55
    let gap: CGFloat = 26
    let centers = [CGPoint(x: body.midX - gap, y: eyeY), CGPoint(x: body.midX + gap, y: eyeY)]
    for (index, c) in centers.enumerated() {
        switch pose.eyes {
        case .open:
            NSBezierPath(roundedRect: CGRect(x: c.x - 8, y: c.y - 19, width: 16, height: 38), xRadius: 8, yRadius: 8).fill()
        case .focused:
            NSBezierPath(roundedRect: CGRect(x: c.x - 8 + 3, y: c.y - 16, width: 16, height: 28), xRadius: 8, yRadius: 8).fill()
        case .up:
            NSBezierPath(roundedRect: CGRect(x: c.x - 8 - 3, y: c.y - 12, width: 16, height: 36), xRadius: 8, yRadius: 8).fill()
        case .down:
            NSBezierPath(roundedRect: CGRect(x: c.x - 8, y: c.y - 24, width: 16, height: 32), xRadius: 8, yRadius: 8).fill()
        case .wide:
            NSBezierPath(ovalIn: CGRect(x: c.x - 12, y: c.y - 17, width: 24, height: 40)).fill()
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: CGRect(x: c.x - 2, y: c.y + 10, width: 8, height: 8)).fill()
            ink.setFill()
        case .closed:
            let line = NSBezierPath(roundedRect: CGRect(x: c.x - 15, y: c.y - 6, width: 30, height: 7), xRadius: 3.5, yRadius: 3.5)
            line.fill()
        case .happy:
            let arc = NSBezierPath()
            arc.appendArc(withCenter: CGPoint(x: c.x, y: c.y - 8), radius: 14, startAngle: 20, endAngle: 160)
            arc.lineWidth = 7
            arc.lineCapStyle = .round
            arc.stroke()
        case .sad:
            let slant: CGFloat = index == 0 ? -1 : 1
            let path = NSBezierPath()
            path.move(to: CGPoint(x: c.x - 14, y: c.y - 4 + 5 * slant))
            path.line(to: CGPoint(x: c.x + 14, y: c.y - 4 - 5 * slant))
            path.lineWidth = 7
            path.lineCapStyle = .round
            path.stroke()
        }
    }
    let mouthY = body.minY + body.height * 0.3
    switch pose.mouth {
    case .none: break
    case .smile:
        let arc = NSBezierPath()
        arc.appendArc(withCenter: CGPoint(x: body.midX, y: mouthY + 12), radius: 16, startAngle: 200, endAngle: 340)
        arc.lineWidth = 6
        arc.lineCapStyle = .round
        arc.stroke()
    case .frown:
        let arc = NSBezierPath()
        arc.appendArc(withCenter: CGPoint(x: body.midX, y: mouthY - 8), radius: 14, startAngle: 30, endAngle: 150)
        arc.lineWidth = 6
        arc.lineCapStyle = .round
        arc.stroke()
    case .open:
        NSBezierPath(ovalIn: CGRect(x: body.midX - 7, y: mouthY - 4, width: 14, height: 14)).fill()
    }
    // Cheeks.
    blend(base, NSColor(srgbRed: 1, green: 0.55, blue: 0.6, alpha: 1), 0.45).withAlphaComponent(0.55).setFill()
    for x in [body.midX - gap - 26, body.midX + gap + 12] {
        NSBezierPath(ovalIn: CGRect(x: x, y: eyeY - 30, width: 14, height: 9)).fill()
    }

    if pose.headphones {
        let cup = NSColor(srgbRed: 0.16, green: 0.17, blue: 0.2, alpha: 1)
        cup.setFill()
        for x in [body.minX - 4, body.maxX - 22] {
            NSBezierPath(roundedRect: CGRect(x: x, y: body.midY - 22, width: 26, height: 46), xRadius: 11, yRadius: 11).fill()
        }
        NSColor(srgbRed: 0.30, green: 0.55, blue: 1.0, alpha: 1).setFill()
        for x in [body.minX + 2, body.maxX - 16] {
            NSBezierPath(roundedRect: CGRect(x: x, y: body.midY - 12, width: 14, height: 26), xRadius: 6, yRadius: 6).fill()
        }
    }
    cg.restoreGState()

    // Small things around the figure (outside the rotation).
    if pose.sparkles {
        NSColor(srgbRed: 1, green: 0.85, blue: 0.4, alpha: 1).setFill()
        let stars: [(CGFloat, CGFloat, CGFloat)] = [(28, 186, 7), (210, 200, 9), (198, 150, 5)]
        for (x, y, r) in stars {
            let star = NSBezierPath()
            for i in 0..<8 {
                let angle = CGFloat(i) * .pi / 4
                let radius = i % 2 == 0 ? r : r * 0.38
                let point = CGPoint(x: x + CGFloat(Foundation.cos(Double(angle))) * radius, y: y + CGFloat(Foundation.sin(Double(angle))) * radius)
                i == 0 ? star.move(to: point) : star.line(to: point)
            }
            star.close()
            star.fill()
        }
    }
    if pose.bubble {
        NSColor.white.withAlphaComponent(0.85).setFill()
        NSBezierPath(ovalIn: CGRect(x: 186, y: 182, width: 22, height: 22)).fill()
        NSBezierPath(ovalIn: CGRect(x: 172, y: 166, width: 10, height: 10)).fill()
    }
    if pose.dots {
        NSColor.white.withAlphaComponent(0.85).setFill()
        for i in 0..<3 {
            NSBezierPath(ovalIn: CGRect(x: 178 + CGFloat(i) * 14, y: 186, width: 9, height: 9)).fill()
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

struct SpriteEntry: Encodable {
    var file: String
    var sourceHeight: Int
}

struct CharacterEntry: Encodable {
    var id: String
    var name: String
    var tint: String
    var portrait: SpriteEntry
    var states: [String: SpriteEntry]
}

func hex(_ color: NSColor) -> String {
    let c = color.usingColorSpace(.sRGB)!
    return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
}

var characters: [CharacterEntry] = []
for pebble in pebbles {
    let folder = output.appending(path: pebble.id)
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    var states: [String: SpriteEntry] = [:]
    for pose in poses {
        let data = render(pebble, pose).representation(using: .png, properties: [:])!
        try data.write(to: folder.appending(path: "\(pose.state).png"))
        states[pose.state] = SpriteEntry(file: "\(pebble.id)/\(pose.state).png", sourceHeight: Int(size.height))
    }
    let portrait = render(pebble, Pose(state: "portrait", eyes: .open, mouth: .smile))
    try portrait.representation(using: .png, properties: [:])!.write(to: folder.appending(path: "portrait.png"))
    characters.append(CharacterEntry(id: pebble.id, name: pebble.name, tint: hex(pebble.color),
                                     portrait: SpriteEntry(file: "\(pebble.id)/portrait.png", sourceHeight: Int(size.height)),
                                     states: states))
}

struct Manifest: Encodable {
    var format = 1
    var id = "pebbles"
    var name = "Pebbles"
    var version = "1.0"
    var license = "Apache-2.0"
    var author = "The Starnotch authors"
    var characters: [CharacterEntry]
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(Manifest(characters: characters)).write(to: output.appending(path: "manifest.json"))
print("Wrote \(characters.count) characters with \(poses.count) states to \(output.path)")
