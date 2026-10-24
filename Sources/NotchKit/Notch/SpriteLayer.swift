import AppKit
import CoreImage
import NotchCore
import QuartzCore
import SwiftUI

/// A sprite on Core Animation layers with its idle life (breathing, blink squash, hops, shake).
/// CA animations run in the window server, so a row of living figures costs the app almost
/// nothing per frame; SwiftUI keyframes would redraw the island 120 times a second.
struct SpriteLayerView: NSViewRepresentable {
    let image: NSImage
    let colorway: Colorway
    let mood: AvatarMood
    let alive: Bool
    /// The pack's finish: a soft outer glow in this colour, and a top highlight (0 to 1).
    var glow: (color: CGColor, amount: Double)? = nil
    var highlight: Double = 0

    func makeNSView(context: Context) -> SpriteHostView { SpriteHostView() }

    func updateNSView(_ view: SpriteHostView, context: Context) {
        let tinted = SpriteTint.image(image, colorway, highlight: highlight)
        view.update(image: tinted, mood: mood,
                    alive: alive && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                    glow: tinted.map { SpriteTint.isDark($0, colorway) } ?? false, colorGlow: glow)
    }
}

final class SpriteHostView: NSView {
    private let hopLayer = CALayer()      // hops and shakes (translation)
    private let beatLayer = CALayer()     // the beat when the state changes (scale)
    private let squashLayer = CALayer()   // blink-like squash (scale)
    private let imageLayer = CALayer()    // breathing (scale.y) and the picture
    private let previousLayer = CALayer() // the last picture, fading out over the new one
    private var mood: AvatarMood?
    private var alive = false
    private var aspect: CGFloat = 1
    private let phase = Double.random(in: 0...3)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        for sub in [hopLayer, beatLayer, squashLayer, imageLayer] {
            sub.anchorPoint = CGPoint(x: 0.5, y: 0)  // grow and squash from the edge it leans on
        }
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.magnificationFilter = .trilinear
        imageLayer.minificationFilter = .trilinear
        previousLayer.contentsGravity = .resizeAspect
        previousLayer.magnificationFilter = .trilinear
        previousLayer.minificationFilter = .trilinear
        previousLayer.opacity = 0
        imageLayer.addSublayer(previousLayer)
        layer?.addSublayer(hopLayer)
        hopLayer.addSublayer(beatLayer)
        beatLayer.addSublayer(squashLayer)
        squashLayer.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bounds = self.bounds
        for sub in [hopLayer, beatLayer, squashLayer] {
            sub.bounds = bounds
            sub.position = CGPoint(x: bounds.midX, y: 0)
        }
        squashLayer.position = CGPoint(x: bounds.midX, y: 0)
        hopLayer.position = CGPoint(x: bounds.midX, y: 0)
        squashLayer.bounds = bounds
        imageLayer.bounds = bounds
        imageLayer.position = CGPoint(x: bounds.midX, y: 0)
        imageLayer.contentsScale = window?.backingScaleFactor ?? 2
        previousLayer.frame = imageLayer.bounds
        previousLayer.contentsScale = imageLayer.contentsScale
        CATransaction.commit()
    }

    func update(image: CGImage?, mood: AvatarMood, alive: Bool, glow: Bool = false,
                colorGlow: (color: CGColor, amount: Double)? = nil) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        swap(to: image, moodChanged: mood != self.mood)
        // Dark figures on the black card: a faint cool glow from the sprite's own alpha (the
        // layer shadow follows the contents), so the silhouette reads without an outline.
        // A pack's own glow (a star that shines) is softer and wider, in its colour.
        if glow {
            imageLayer.shadowOpacity = 0.32
            imageLayer.shadowColor = SpriteTint.rimColor
            imageLayer.shadowRadius = 3
        } else if let colorGlow {
            imageLayer.shadowOpacity = Float(min(1, colorGlow.amount))
            imageLayer.shadowColor = colorGlow.color
            imageLayer.shadowRadius = 5
        } else {
            imageLayer.shadowOpacity = 0
        }
        imageLayer.shadowOffset = .zero
        CATransaction.commit()
        guard mood != self.mood || alive != self.alive else { return }
        let previous = self.mood
        self.mood = mood
        self.alive = alive
        configure(previous: previous)
    }

    // MARK: Swapping pictures

    /// Never a hard cut: the new picture cross-fades over the old one (the frames are aligned, so
    /// it reads as the face changing), with a small squash-and-settle when the mood changed. A
    /// change of look alone (the cat's eyes for another effort level) only fades. Flips within
    /// 1.5 s of the last swap wait until then, so busy↔idle flicker collapses into one change.
    static let settle: TimeInterval = 1.5
    private var lastSwap = Date.distantPast
    private var pending: (image: CGImage?, beat: Bool)?
    private var pendingTask: DispatchWorkItem?

    private func swap(to image: CGImage?, moodChanged: Bool) {
        let current = imageLayer.contents as! CGImage?
        guard current !== image else { pending = nil; pendingTask?.cancel(); return }
        // First picture: no animation.
        guard current != nil else { imageLayer.contents = image; return }
        let wait = Self.settle - Date().timeIntervalSince(lastSwap)
        if wait > 0 {
            pending = (image, (pending?.beat ?? false) || moodChanged)
            if pendingTask == nil {
                let task = DispatchWorkItem { [weak self] in
                    guard let self, let pending = self.pending else { return }
                    self.pending = nil
                    self.pendingTask = nil
                    self.apply(pending.image, beat: pending.beat)
                }
                pendingTask = task
                DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: task)
            }
            return
        }
        apply(image, beat: moodChanged)
    }

    private func apply(_ image: CGImage?, beat: Bool) {
        guard imageLayer.contents as! CGImage? !== image else { return }
        lastSwap = Date()
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // The old picture sits on top of the new one and fades out: a dissolve without the
        // see-through dip of two half-transparent pictures.
        previousLayer.contents = imageLayer.contents
        previousLayer.opacity = 0
        imageLayer.contents = image
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = reduce ? 0.15 : 0.24
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        previousLayer.add(fade, forKey: "swap")
        guard beat, !reduce else { return }
        let pop = CAKeyframeAnimation(keyPath: "transform")
        pop.values = [CATransform3DIdentity, CATransform3DMakeScale(1.02, 0.97, 1), CATransform3DMakeScale(0.99, 1.02, 1),
                      CATransform3DIdentity].map { NSValue(caTransform3D: $0) }
        pop.keyTimes = [0, 0.3, 0.65, 1]
        pop.duration = 0.42
        pop.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut),
                               CAMediaTimingFunction(name: .easeOut)]
        beatLayer.add(pop, forKey: "beat")
    }

    private var lively: Bool {
        [.working, .thinking, .typing, .music, .listening].contains(mood ?? .idle)
    }

    private func configure(previous: AvatarMood?) {
        for sub in [hopLayer, squashLayer, imageLayer] { sub.removeAllAnimations() }
        guard alive, let mood else { return }
        let now = CACurrentMediaTime()

        // Breathing: about 1.5 %, slower at rest, quicker at work; random phase per figure.
        let breathe = CABasicAnimation(keyPath: "transform.scale.y")
        breathe.fromValue = 0.996
        breathe.toValue = 1.016
        breathe.duration = lively ? 0.9 : 1.8
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        breathe.beginTime = now + phase.truncatingRemainder(dividingBy: breathe.duration)
        imageLayer.add(breathe, forKey: "breathe")

        // Blink-like squash once per cycle, at a random point of it.
        let cycle = lively ? Double.random(in: 2.5...5) : Double.random(in: 4...9)
        let squash = CAKeyframeAnimation(keyPath: "transform")
        let at = Double.random(in: 0.2...0.8)
        let squashed = CATransform3DMakeScale(1.06, 0.88, 1)
        squash.values = [CATransform3DIdentity, CATransform3DIdentity, squashed, CATransform3DMakeScale(0.98, 1.04, 1), CATransform3DIdentity, CATransform3DIdentity]
            .map { NSValue(caTransform3D: $0) }
        let step = 0.1 / cycle
        squash.keyTimes = [0, at, at + step, at + 2 * step, at + 3.5 * step, 1].map { NSNumber(value: min(1, $0)) }
        squash.duration = cycle
        squash.repeatCount = .infinity
        squash.beginTime = now + phase
        squashLayer.add(squash, forKey: "squash")

        switch mood {
        case .yourTurn:
            // "Hey": a small hop every eight seconds.
            hopLayer.add(hops(count: 1, height: bounds.height * 0.08, period: 8, repeating: true, now: now), forKey: "hey")
        case .finished where previous != .finished:
            hopLayer.add(hops(count: 2, height: bounds.height * 0.12, period: 1.1, repeating: false, now: now), forKey: "celebrate")
        case .failed where previous != .failed:
            let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
            shake.values = [0, 5, -5, 4, -3, 0]
            shake.duration = 0.32
            shake.beginTime = now
            hopLayer.add(shake, forKey: "shake")
        default:
            break
        }
    }

    private func hops(count: Int, height: CGFloat, period: Double, repeating: Bool, now: CFTimeInterval) -> CAAnimation {
        let hop = CAKeyframeAnimation(keyPath: "transform.translation.y")
        let jump = 0.5 / period   // one hop takes half a second
        var values: [CGFloat] = [0]
        var times: [Double] = [0]
        for index in 0..<count {
            let start = Double(index) * jump
            values += [0, height, 0, height * 0.18, 0]
            times += [start, start + jump * 0.35, start + jump * 0.7, start + jump * 0.85, start + jump]
        }
        values.append(0)
        times.append(1)
        hop.values = values
        hop.keyTimes = times.map { NSNumber(value: min(1, $0)) }
        hop.duration = period
        hop.repeatCount = repeating ? .infinity : 1
        hop.beginTime = now + (repeating ? 2 : 0)
        return hop
    }
}

/// Hue-shifted sprites, rendered once with Core Image and cached. Dark results (Matte Black, or
/// any sprite whose luminance is low) get a soft rim light so they don't sink into the black card.
@MainActor
enum SpriteTint {
    private static var cache: [String: CGImage] = [:]
    private static var darkness: [ObjectIdentifier: Bool] = [:]
    private static let context = CIContext(options: [.cacheIntermediates: false])
    /// Cool grey of the rim and the glow.
    static let rimColor = CGColor(red: 0.78, green: 0.82, blue: 0.90, alpha: 1)

    static func image(_ image: NSImage, _ colorway: Colorway, highlight: Double = 0) -> CGImage? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let key = "\(ObjectIdentifier(image).hashValue)|\(highlight)|\(colorway.hue)|\(colorway.saturation)|\(colorway.brightness)|\(colorway.contrast)|\(colorway.shade)|\(colorway.tint ?? 0)|\(colorway.tintAmount)"
        if let cached = cache[key] { return cached }
        var tinted = colorway.isIdentity ? source : recolor(source, colorway)
        if highlight > 0 { tinted = highlighted(tinted, amount: highlight) ?? tinted }
        let result = isDark(tinted, colorway) ? (rimLit(tinted) ?? tinted) : tinted
        if cache.count > 400 { cache.removeAll() }
        cache[key] = result
        return result
    }

    /// Dark colorway, or an alpha-weighted luminance under 0.22.
    static func isDark(_ image: CGImage, _ colorway: Colorway) -> Bool {
        if colorway.isDark { return true }
        let id = ObjectIdentifier(image)
        if let known = darkness[id] { return known }
        let input = CIImage(cgImage: image)
        let average = input.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: input.extent)])
        var pixel = [Float](repeating: 0, count: 4)
        context.render(average, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        // Premultiplied average: divide by the coverage to get the figure's own colour.
        let alpha = max(pixel[3], 0.0001)
        let luminance = (0.2126 * pixel[0] + 0.7152 * pixel[1] + 0.0722 * pixel[2]) / alpha
        let dark = pixel[3] > 0.01 && luminance < 0.22
        if darkness.count > 400 { darkness.removeAll() }
        darkness[id] = dark
        return dark
    }

    /// A soft light edge inside the silhouette, derived from its alpha: no hard outline, no
    /// sticker look. The small sprites are upscaled first so the edge can be finer than one of
    /// their pixels (about 1 to 1.5 pt on the big card figure).
    private static func rimLit(_ image: CGImage) -> CGImage? {
        let scale = max(1, min(4, 300 / CGFloat(max(image.height, 1))))
        let input = CIImage(cgImage: image)
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
        let extent = input.extent.integral
        let c = CIColor(cgColor: rimColor)
        // The silhouette in the rim colour, with the sprite's alpha.
        let silhouette = input.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: c.red, y: c.green, z: c.blue, w: 0),
        ])
        let inner = silhouette.clampedToExtent()
            .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 2.0])
            .cropped(to: extent)
        // The ring between the silhouette and its eroded self, softened, kept inside the figure.
        let ring = silhouette.applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: inner])
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.4])
            .cropped(to: extent)
            .applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: silhouette])
        // Light from above: full on the upper edge, fading toward the bottom, so it reads as a
        // light and not as an outline.
        let falloff = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: extent.midX, y: extent.maxY),
            "inputPoint1": CIVector(x: extent.midX, y: extent.minY + extent.height * 0.25),
            "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 0.5),
            "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 0.08),
        ])?.outputImage?.cropped(to: extent)
        let lightRing = falloff.map {
            ring.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(),
                                                                     kCIInputMaskImageKey: $0])
        } ?? ring.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.42)])
        let lit = lightRing.composited(over: input)
        return context.createCGImage(lit, from: extent)
    }

    /// A soft sheen on the upper part of the figure, inside its silhouette (glossy, like the
    /// concept art), fading out by the middle.
    private static func highlighted(_ image: CGImage, amount: Double) -> CGImage? {
        let input = CIImage(cgImage: image)
        let extent = input.extent
        guard let sheen = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: extent.midX, y: extent.maxY),
            "inputPoint1": CIVector(x: extent.midX, y: extent.minY + extent.height * 0.5),
            "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: CGFloat(min(1, amount))),
            "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 0),
        ])?.outputImage?.cropped(to: extent) else { return nil }
        let lit = sheen.applyingFilter("CISourceAtopCompositing", parameters: [kCIInputBackgroundImageKey: input])
        return context.createCGImage(lit, from: extent)
    }

    private static func recolor(_ source: CGImage, _ colorway: Colorway) -> CGImage {
        var output = CIImage(cgImage: source)
        if colorway.hue != 0 {
            output = output.applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: colorway.hue * .pi / 180])
        }
        if colorway.saturation != 1 || colorway.brightness != 0 || colorway.contrast != 1 {
            output = output.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: colorway.saturation,
                                                                           kCIInputBrightnessKey: colorway.brightness,
                                                                           kCIInputContrastKey: colorway.contrast])
        }
        if let tint = colorway.tint, colorway.tintAmount > 0 {
            let color = CIColor(red: CGFloat((tint >> 16) & 0xFF) / 255, green: CGFloat((tint >> 8) & 0xFF) / 255,
                                blue: CGFloat(tint & 0xFF) / 255)
            output = output.applyingFilter("CIColorMonochrome", parameters: [kCIInputColorKey: color,
                                                                             kCIInputIntensityKey: colorway.tintAmount])
        }
        if colorway.shade != 1 {
            let m = CGFloat(colorway.shade)
            output = output.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: m, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: m, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: m * 1.12, w: 0),  // a touch of blue: slate, not grey
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
        }
        return context.createCGImage(output, from: output.extent) ?? source
    }
}

/// Four bars in a colour, moving while music plays: Core Animation, no per-frame work in the app.
struct Equalizer: NSViewRepresentable {
    let color: Color
    let playing: Bool
    var height: CGFloat = 12

    func makeNSView(context: Context) -> EqualizerView { EqualizerView() }

    func updateNSView(_ view: EqualizerView, context: Context) {
        view.update(color: NSColor(color), playing: playing && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                    height: height)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: EqualizerView, context: Context) -> CGSize? {
        CGSize(width: 4 * 2.5 + 3 * 2, height: height)
    }
}

final class EqualizerView: NSView {
    private var bars: [CALayer] = []
    private var playing: Bool?
    private var barHeight: CGFloat = 12

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for _ in 0..<4 {
            let bar = CALayer()
            bar.anchorPoint = CGPoint(x: 0.5, y: 0)
            bar.cornerRadius = 1
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: 2.5, height: barHeight)
            bar.position = CGPoint(x: CGFloat(index) * 4.5 + 1.25, y: 0)
        }
        CATransaction.commit()
    }

    func update(color: NSColor, playing: Bool, height: CGFloat) {
        barHeight = height
        for bar in bars { bar.backgroundColor = color.cgColor }
        guard playing != self.playing else { return }
        self.playing = playing
        needsLayout = true
        let durations = [0.42, 0.31, 0.55, 0.37]
        for (index, bar) in bars.enumerated() {
            bar.removeAllAnimations()
            if playing {
                let pulse = CABasicAnimation(keyPath: "transform.scale.y")
                pulse.fromValue = 0.25
                pulse.toValue = 1
                pulse.duration = durations[index]
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                pulse.timeOffset = Double(index) * 0.13
                bar.add(pulse, forKey: "pulse")
            } else {
                bar.transform = CATransform3DMakeScale(1, 0.25, 1)
            }
        }
    }
}
