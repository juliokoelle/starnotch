// Builds Resources/Characters/astra.notchpack from an Astra image export, 1024 × 1024 RGBA, same
// framing throughout, in either layout:
//   - flat, as art/astra/astra.py renders it: `astra_<colour>_<state>.png`
//   - one folder per colour (Nova, Aurora, …) with `starnotch_<colour>_<state>.png`
// Replacing the art is: render or export the new set, run this, rebuild.
//
//   swift scripts/make-astra-pack.swift <export folder> [Resources/Characters/astra.notchpack]
//
// Every state is cut to the same frame (the union of the figures including any soft halo, so
// the star stands on the same baseline in every state and the glow isn't clipped); `peek`
// (upper half) is cut to its own bottom edge. Images are scaled down with Lanczos to 240 px
// tall: the biggest figure the app draws is 118 pt, 236 px at 2x.
import AppKit
import CoreImage
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("usage: swift scripts/make-astra-pack.swift <export folder> [output.notchpack]")
    exit(1)
}
let input = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments.count > 2 ? arguments[2] : "Resources/Characters/astra.notchpack")
let fm = FileManager.default
let targetHeight: CGFloat = 240

/// Colour folder, file key, display name, accent, effort level it stands for by default.
let colours: [(folder: String, key: String, name: String, tint: String, level: String)] = [
    ("Nova", "nova", "Nova", "#6E7BFF", "medium"),
    ("Mint", "mint", "Mint", "#3ED6A0", "low"),
    ("Aurora", "aurora", "Aurora", "#E46BE0", "high"),
    ("Cosmo", "cosmo", "Cosmo", "#6A4FC8", "xhigh"),
    ("Sol", "sol", "Sol", "#FF9A3C", "max"),
    ("Rosé", "rose", "Rosé", "#FF6FA8", "ultra"),
]
/// App state → exported expression.
let mapping: [(state: String, asset: String)] = [
    ("idle", "neutral"), ("working", "determined"), ("thinking", "thinking"), ("surprised", "surprised"),
    ("excited", "excited"), ("celebrating", "joyful"), ("happy", "happy"), ("error_problem", "confused"),
    ("angry", "angry"), ("sleepy", "sleepy"), ("sleeping", "sleep"), ("love", "love"), ("peek", "peek"),
    ("voice_listening", "happy"),
]
let assets = Array(Set(mapping.map(\.asset))).sorted()

/// Finds a file whatever the Unicode normalisation of its name (Rosé).
func find(_ name: String, in folder: URL) -> URL? {
    let wanted = name.precomposedStringWithCanonicalMapping.lowercased()
    let entries = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    return entries.first { $0.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased() == wanted }
}

func load(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

/// Bounding box of pixels with alpha above ~1 % (a halo's faint edge counts), top-left coordinates.
func alphaBox(_ image: CGImage) -> CGRect {
    let w = image.width, h = image.height
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    var minX = w, minY = h, maxX = -1, maxY = -1
    for y in 0..<h { for x in 0..<w where pixels[(y * w + x) * 4 + 3] > 2 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    } }
    return maxX < 0 ? .zero : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

let ci = CIContext()
func write(_ image: CGImage, crop: CGRect, scale: CGFloat, to url: URL) throws {
    guard let piece = image.cropping(to: crop) else { throw CocoaError(.fileWriteUnknown) }
    let scaled = CIImage(cgImage: piece).applyingFilter("CILanczosScaleTransform",
                                                         parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
    guard let out = ci.createCGImage(scaled, from: scaled.extent.integral, format: .RGBA8,
                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { throw CocoaError(.fileWriteUnknown) }
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])!.write(to: url)
}

// Load everything, then find the shared frame.
var images: [String: [String: CGImage]] = [:]
var frame = CGRect.null
for colour in colours {
    let folder = find(colour.folder, in: input)
    for asset in assets {
        let name = "starnotch_\(colour.key == "rose" ? "rosé" : colour.key)_\(asset).png"
        let url = folder.flatMap { find(name, in: $0) ?? find("starnotch_\(colour.key)_\(asset).png", in: $0) }
            ?? find("astra_\(colour.key)_\(asset).png", in: input)
        guard let url, let image = load(url) else { print("missing \(colour.key) \(asset)"); exit(1) }
        images[colour.key, default: [:]][asset] = image
        if asset != "peek" { frame = frame.union(alphaBox(image)) }
    }
}
let scale = targetHeight / frame.height
let license = try? Data(contentsOf: output.appending(path: "LICENSE"))  // kept across the rebuild
try? fm.removeItem(at: output)

var sprites: [String: [String: [String: Any]]] = [:]   // colour → state → sprite
for colour in colours {
    for (state, asset) in mapping {
        let image = images[colour.key]![asset]!
        var crop = frame
        if asset == "peek" { let box = alphaBox(image); crop.size.height = box.maxY - frame.minY }
        let file = "astra/\(colour.key)/\(asset).png"
        if !fm.fileExists(atPath: output.appending(path: file).path) {
            try write(image, crop: crop, scale: scale, to: output.appending(path: file))
        }
        sprites[colour.key, default: [:]][state] = ["file": file, "sourceHeight": Int((crop.height * scale).rounded())]
    }
}

var levels: [String: Any] = [:]
for colour in colours {
    var variant: [String: Any] = ["name": colour.name, "tint": colour.tint]
    if colour.key != "nova" { variant["states"] = sprites[colour.key]! }  // Nova is the base look
    levels[colour.level] = variant
}
let manifest: [String: Any] = [
    "format": 1, "id": "astra", "name": "Astra", "version": "1.0", "license": "Copyright © 2026 Julio Koelle. All rights reserved. See LICENSE in this pack.",
    "author": "The Starnotch authors",
    "recipes": [
        ["key": "astra_mint", "name": "Mint (tint)", "tint": "#3ED6A0", "tintAmount": 0.75],
        ["key": "astra_aurora", "name": "Aurora (tint)", "tint": "#E46BE0", "tintAmount": 0.55],
        ["key": "astra_cosmo", "name": "Cosmo (tint)", "tint": "#6A4FC8", "tintAmount": 0.6, "shade": 0.4],
        ["key": "astra_sol", "name": "Sol (tint)", "tint": "#FF9A3C", "tintAmount": 0.8],
        ["key": "astra_rose", "name": "Rosé (tint)", "tint": "#FF6FA8", "tintAmount": 0.75],
    ],
    "characters": [[
        "id": "astra", "name": "Astra", "tint": "#6E7BFF",
        "portrait": sprites["nova"]!["idle"]!,
        "states": sprites["nova"]!,
        "levels": levels,
    ]],
]
let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
try data.write(to: output.appending(path: "manifest.json"))
if let license { try license.write(to: output.appending(path: "LICENSE")) }
print("Wrote \(output.path): \(colours.count) colours × \(assets.count) images, frame \(Int(frame.width))×\(Int(frame.height)) → \(Int(frame.width * scale))×\(Int(targetHeight))")
