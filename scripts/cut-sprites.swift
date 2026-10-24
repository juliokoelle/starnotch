// Cuts character sprites out of reference sheets with Apple Vision (foreground instance masks,
// offline) for a `.notchpack`. A JSON spec lists the crops; the script writes one PNG per crop and
// `cuts.json` with each sprite's height and average colour, for the manifest.
//
//   swift scripts/cut-sprites.swift spec.json <output folder>
//
// Spec: {"scale": 3, "sheets": {"a": "sheet.png"}, "crops": [{"sheet": "a", "file": "fox/idle.png",
//        "rect": [x, y, w, h], "erase": [[cx, cy, r]], "stripBar": false, "props": false}]}
// `rect` is in sheet pixels (top-left origin). `erase` paints circles in the background colour
// first (labels, badges near the figure). `stripBar` removes a dark bar the figure leans on.
// `props` keeps other shapes overlapping the figure (headphones, a laptop). Crops are upscaled by
// `scale` with Lanczos before masking, since small crops mask poorly; `sourceHeight` in cuts.json
// stays in sheet pixels, so the app still knows how much detail a sprite really has.
import AppKit
import CoreImage
import Foundation
import Vision

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    print("usage: swift scripts/cut-sprites.swift spec.json <output folder>")
    exit(1)
}
let specURL = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2])
let fm = FileManager.default

struct Spec: Decodable {
    struct Crop: Decodable {
        var sheet: String
        var file: String
        var rect: [Int]
        var erase: [[Int]]?
        var stripBar: Bool?
        var props: Bool?
    }
    var scale: Double?
    var sheets: [String: String]
    var crops: [Crop]
}

func loadCGImage(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

/// The crop with circles painted over in the crop's corner colour, upscaled.
func prepare(_ sheet: CGImage, _ crop: Spec.Crop, scale: Double) -> CGImage? {
    let r = crop.rect
    guard r.count == 4, let piece = sheet.cropping(to: CGRect(x: r[0], y: r[1], width: r[2], height: r[3])) else { return nil }
    let w = piece.width, h = piece.height
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(piece, in: CGRect(x: 0, y: 0, width: w, height: h))
    // Memory rows are top-down: index 0 is the top-left pixel.
    let corner = CGColor(srgbRed: CGFloat(pixels[0]) / 255, green: CGFloat(pixels[1]) / 255, blue: CGFloat(pixels[2]) / 255, alpha: 1)
    context.setFillColor(corner)
    for circle in crop.erase ?? [] where circle.count == 3 {
        let cx = CGFloat(circle[0] - r[0]), cy = CGFloat(circle[1] - r[1]), radius = CGFloat(circle[2])
        // Context coordinates are bottom-up.
        context.fillEllipse(in: CGRect(x: cx - radius, y: CGFloat(h) - cy - radius, width: 2 * radius, height: 2 * radius))
    }
    guard let painted = context.makeImage() else { return nil }
    guard scale > 1 else { return painted }
    let ci = CIImage(cgImage: painted).applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
    return CIContext().createCGImage(ci, from: ci.extent.integral, format: .RGBA8, colorSpace: space)
}

func cutOut(_ cg: CGImage, name: String, stripBar: Bool, keepProps: Bool) -> (CGImage, Int, (Double, Double, Double))? {
    let url = URL(fileURLWithPath: name)
    let request = VNGenerateForegroundInstanceMaskRequest()
    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    do { try handler.perform([request]) } catch { print("  vision failed: \(error)"); return nil }
    guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
        print("  no foreground: \(url.lastPathComponent)")
        return nil
    }

    let width = cg.width, height = cg.height
    // One mask per instance at source resolution.
    var masks: [(index: Int, alpha: [Float], box: (Int, Int, Int, Int), area: Int)] = []
    for instance in observation.allInstances {
        guard let buffer = try? observation.generateScaledMaskForImage(forInstances: IndexSet(integer: instance), from: handler) else { continue }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!
        var alpha = [Float](repeating: 0, count: width * height)
        var minX = width, minY = height, maxX = -1, maxY = -1, area = 0
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
            for x in 0..<width {
                let a = row[x]
                alpha[y * width + x] = a
                if a > 0.5 {
                    area += 1
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        if area > 0 { masks.append((instance, alpha, (minX, minY, maxX, maxY), area)) }
    }
    // The character: the largest instance that isn't a wide flat strip (the notch bar or a tile edge).
    let candidates = masks.filter { mask in
        let w = mask.box.2 - mask.box.0 + 1, h = mask.box.3 - mask.box.1 + 1
        return !(Double(w) > Double(width) * 0.8 && Double(h) < Double(height) * 0.3)
    }
    guard let main = candidates.max(by: { $0.area < $1.area }) else { return nil }
    // Props touching the character's box (laptop, headphones) stay.
    var combined = main.alpha
    for mask in candidates where keepProps && mask.index != main.index {
        let b = mask.box, m = main.box
        let ix = max(0, min(b.2, m.2) - max(b.0, m.0)), iy = max(0, min(b.3, m.3) - max(b.1, m.1))
        let overlap = Double(ix * iy) / Double(max(1, (b.2 - b.0) * (b.3 - b.1)))
        if overlap > 0.5 { for i in 0..<combined.count { combined[i] = max(combined[i], mask.alpha[i]) } }
    }

    // Read the pixels.
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let bitmap = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                           space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    bitmap.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

    func luma(_ i: Int) -> Int { (Int(pixels[i * 4]) * 3 + Int(pixels[i * 4 + 1]) * 6 + Int(pixels[i * 4 + 2])) / 10 }

    // The notch bar the figures lean on: the first row in the lower half where a long run of
    // near-black masked pixels starts. Everything from just above it down goes (bar and bezel).
    func chroma(_ i: Int) -> Int {
        let r = Int(pixels[i * 4]), g = Int(pixels[i * 4 + 1]), b = Int(pixels[i * 4 + 2])
        return max(r, g, b) - min(r, g, b)
    }
    // Bottom 40 % only, and neutral black: dark-blue or black-bodied colorways are not the bar.
    for y in (height * 3 / 5)..<height where stripBar {
        var run = 0, best = 0
        for x in 0..<width {
            let i = y * width + x
            if combined[i] > 0.5 && luma(i) < 48 && chroma(i) < 45 { run += 1; best = max(best, run) } else { run = 0 }
        }
        if Double(best) > Double(width) * 0.33 {
            let cut = max(0, y - 2)
            for yy in cut..<height { for x in 0..<width { combined[yy * width + x] = 0 } }
            break
        }
    }

    // Whole tile instead of a figure: Vision gave up on the background (crops here are tight,
    // so a figure may touch every edge; judge by covered area instead).
    let covered = combined.reduce(0) { $0 + ($1 > 0.5 ? 1 : 0) }
    if Double(covered) > Double(width * height) * 0.92 {
        print("  whole tile, skipped: \(url.lastPathComponent)")
        return nil
    }

    // Holes inside the figure (dark eyes, an open mouth) belong to it: background is only what
    // the tile's border reaches.
    do {
        var outside = [Bool](repeating: false, count: width * height)
        var stack: [Int] = []
        for x in 0..<width { stack.append(x); stack.append((height - 1) * width + x) }
        for y in 0..<height { stack.append(y * width); stack.append(y * width + width - 1) }
        while let i = stack.popLast() {
            guard !outside[i], combined[i] <= 0.5 else { continue }
            outside[i] = true
            let x = i % width, y = i / width
            if x > 0 { stack.append(i - 1) }
            if x < width - 1 { stack.append(i + 1) }
            if y > 0 { stack.append(i - width) }
            if y < height - 1 { stack.append(i + width) }
        }
        for i in 0..<(width * height) where combined[i] <= 0.5 && !outside[i] { combined[i] = 1 }
    }

    // Keep the figure's connected piece and big props; drop bezel arcs, tile edges, specks.
    var label = [Int](repeating: 0, count: width * height)
    var sizes: [Int] = [0]
    for start in 0..<(width * height) where combined[start] > 0.5 && label[start] == 0 {
        let id = sizes.count
        var stack = [start], size = 0
        label[start] = id
        while let i = stack.popLast() {
            size += 1
            let x = i % width, y = i / width
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < width && ny < height {
                let j = ny * width + nx
                if combined[j] > 0.5 && label[j] == 0 { label[j] = id; stack.append(j) }
            }
        }
        sizes.append(size)
    }
    let largest = sizes.max() ?? 0
    guard largest > 40 else { return nil }
    for i in 0..<(width * height) {
        let id = label[i]
        let keep = id > 0 && Double(sizes[id]) >= Double(largest) * 0.12
        // Soft edge pixels (alpha <= 0.5) stay only next to kept pixels.
        if id > 0 && !keep { combined[i] = 0 }
        if id == 0 && combined[i] > 0 {
            let x = i % width, y = i / width
            var near = false
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < width && ny < height {
                let l = label[ny * width + nx]
                if l > 0 && Double(sizes[l]) >= Double(largest) * 0.12 { near = true }
            }
            if !near { combined[i] = 0 }
        }
    }

    // Mask rows are top-down like the bitmap memory.
    var minX = width, minY = height, maxX = -1, maxY = -1
    var r = 0.0, g = 0.0, bl = 0.0, weight = 0.0
    for y in 0..<height {
        for x in 0..<width {
            let a = combined[y * width + x]
            let i = (y * width + x) * 4
            let alpha = UInt8(max(0, min(255, a * 255)))
            for c in 0..<3 { pixels[i + c] = UInt8(Float(pixels[i + c]) * Float(alpha) / 255) }
            pixels[i + 3] = alpha
            if a > 0.5 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                let red = Double(pixels[i]), green = Double(pixels[i + 1]), blue = Double(pixels[i + 2])
                let sat = (max(red, green, blue) - min(red, green, blue)) / 255
                let w = 0.05 + sat
                r += red * w; g += green * w; bl += blue * w; weight += w
            }
        }
    }
    guard maxX >= minX, maxY >= minY else { return nil }
    let masked = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                           space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    let pad = 2
    let crop = CGRect(x: max(0, minX - pad), y: max(0, minY - pad),
                      width: min(width, maxX + pad + 1) - max(0, minX - pad),
                      height: min(height, maxY + 1) - max(0, minY - pad))  // no pad below: the edge it leans on
    guard let trimmed = masked.cropping(to: crop) else { return nil }

    let out = trimmed
    let tint = weight > 0 ? (r / weight, g / weight, bl / weight) : (128, 128, 128)
    return (out, maxY - minY + 1, tint)
}

func write(_ image: CGImage, to url: URL) {
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let rep = NSBitmapImageRep(cgImage: image)
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
}

let spec = try JSONDecoder().decode(Spec.self, from: Data(contentsOf: specURL))
let base = specURL.deletingLastPathComponent()
var sheets: [String: CGImage] = [:]
for (key, path) in spec.sheets {
    let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appending(path: path)
    guard let image = loadCGImage(url) else { print("can't read sheet \(path)"); exit(1) }
    sheets[key] = image
}
let scale = spec.scale ?? 3
var cuts: [String: [String: Any]] = [:]
for crop in spec.crops {
    guard let sheet = sheets[crop.sheet], let prepared = prepare(sheet, crop, scale: scale) else {
        print("skip \(crop.file): bad crop"); continue
    }
    guard let (image, height, tint) = cutOut(prepared, name: crop.file, stripBar: crop.stripBar ?? false,
                                              keepProps: crop.props ?? false) else {
        print("skip \(crop.file): no figure"); continue
    }
    write(image, to: output.appending(path: crop.file))
    let hex = String(format: "#%02X%02X%02X", Int(tint.0), Int(tint.1), Int(tint.2))
    cuts[crop.file] = ["sourceHeight": Int((Double(height) / scale).rounded()), "pixels": image.height, "tint": hex]
    print("\(crop.file): \(image.width)x\(image.height) (sheet \(Int((Double(height) / scale).rounded())) px tall)")
}
let data = try JSONSerialization.data(withJSONObject: cuts, options: [.prettyPrinted, .sortedKeys])
try data.write(to: output.appending(path: "cuts.json"))
