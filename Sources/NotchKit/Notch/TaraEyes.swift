import AppKit
import NotchCore
import Observation
import QuartzCore

/// Tara's eyes as layers of their own on her open-eyed picture, so they follow the pointer, glance
/// around now and then while it rests, and laugh (^ ^) at a click. The picture's
/// own eyes are covered with the face's colour; everything else stays the picture. They ride on
/// the sprite's layers, so they breathe, hop and blink with her.
struct SpriteEyes: Equatable {
    /// The picture's canvas, and its eyes in it (top-left origin, in canvas pixels).
    var canvas: CGSize
    var left: CGRect
    var right: CGRect
    /// A point on the face below the eyes, where its colour is read.
    var faceSample: CGPoint
    /// Where the round eyes get a little mouth, on pictures that draw none of their own.
    var mouth: CGPoint? = nil

    /// Tara (the astra pack) in her open-eyed pictures (neutral, thinking, surprised); every
    /// colourway draws the face in the same place.
    static func forSprite(file: String) -> SpriteEyes? {
        guard file.hasPrefix("astra/") else { return nil }
        let canvas = CGSize(width: 246, height: 240), sample = CGPoint(x: 110, y: 129)  // between the eyes
        switch (file as NSString).lastPathComponent {
        case "neutral.png", "thinking.png":
            // Thinking draws a mouth of its own, neutral none.
            let mouth = file.hasSuffix("neutral.png") ? CGPoint(x: 111, y: 146) : nil
            return SpriteEyes(canvas: canvas, left: CGRect(x: 94, y: 118, width: 9, height: 21),
                              right: CGRect(x: 117, y: 118, width: 10, height: 22), faceSample: sample, mouth: mouth)
        case "surprised.png":
            return SpriteEyes(canvas: canvas, left: CGRect(x: 93, y: 119, width: 11, height: 17),
                              right: CGRect(x: 117, y: 120, width: 11, height: 16), faceSample: sample)
        default:
            return nil
        }
    }
}

/// The eyes: two patches in the face's colour over the picture's eyes, two white pupils on top
/// that move, and two arcs for laughing. The round style adds pink cheeks and a small mouth, after
/// a teammate's mascot sketch: without them round eyes in a dark face looked creepy.
final class EyesLayer: CALayer {
    private let patches = [CALayer(), CALayer()]
    /// The white of each eye (a line, or a round eye), and in the round style its dark pupil.
    private let pupils = [CALayer(), CALayer()]
    private let irises = [CALayer(), CALayer()]
    private var eyeStyle = EyeStyle.lines  // `style` is CALayer's own
    private let arcs = [CAShapeLayer(), CAShapeLayer()]
    private let cheeks = [CAGradientLayer(), CAGradientLayer()]
    private let mouth = CAShapeLayer()
    /// The mouth at rest and as the bigger smile while laughing.
    private var smile: CGPath?
    private var grin: CGPath?
    private var spec: SpriteEyes?
    private var scale: CGFloat = 1
    /// Where the pupils rest, in this layer's coordinates.
    private var centers: [CGPoint] = [.zero, .zero]
    private var look = CGPoint.zero

    override init() {
        super.init()
        for layer in patches { addSublayer(layer) }
        for cheek in cheeks {
            // A radial fade, so the blush has no edge.
            cheek.type = .radial
            cheek.colors = [CGColor(red: 1, green: 0.45, blue: 0.62, alpha: 0.6),
                            CGColor(red: 1, green: 0.45, blue: 0.62, alpha: 0)]
            cheek.startPoint = CGPoint(x: 0.5, y: 0.5)
            cheek.endPoint = CGPoint(x: 1, y: 1)
            addSublayer(cheek)
        }
        mouth.fillColor = nil
        mouth.strokeColor = CGColor(red: 1, green: 1, blue: 1, alpha: 0.85)
        mouth.lineCap = .round
        addSublayer(mouth)
        for (index, layer) in pupils.enumerated() {
            layer.backgroundColor = NSColor.white.cgColor
            irises[index].backgroundColor = CGColor(red: 0.094, green: 0.063, blue: 0.176, alpha: 1)
            layer.addSublayer(irises[index])
            addSublayer(layer)
        }
        blink()
        for arc in arcs {
            arc.fillColor = nil
            arc.strokeColor = NSColor.white.cgColor
            arc.lineCap = .round
            arc.opacity = 0
            addSublayer(arc)
        }
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    /// Lays the eyes out over the picture as `resizeAspect` draws it in `bounds`.
    func place(_ spec: SpriteEyes, in bounds: CGRect, face: CGColor?, style: EyeStyle = .lines) {
        self.spec = spec
        eyeStyle = style
        frame = bounds
        scale = min(bounds.width / spec.canvas.width, bounds.height / spec.canvas.height)
        let origin = CGPoint(x: (bounds.width - spec.canvas.width * scale) / 2,
                             y: (bounds.height - spec.canvas.height * scale) / 2)
        func layerRect(_ r: CGRect) -> CGRect {
            CGRect(x: origin.x + r.minX * scale, y: origin.y + (spec.canvas.height - r.maxY) * scale,
                   width: r.width * scale, height: r.height * scale)
        }
        for (index, eye) in [spec.left, spec.right].enumerated() {
            let rect = layerRect(eye)
            let patch = rect.insetBy(dx: -3.5 * scale, dy: -3.5 * scale)
            patches[index].frame = patch
            patches[index].cornerRadius = patch.width / 2
            patches[index].backgroundColor = face ?? CGColor(red: 0.035, green: 0.02, blue: 0.05, alpha: 1)
            // Round: a white eye about 1.6 times as wide as the line, with a dark pupil in it.
            let size = eyeStyle == .round ? CGSize(width: 15 * scale, height: 17 * scale) : rect.size
            pupils[index].bounds = CGRect(origin: .zero, size: size)
            pupils[index].cornerRadius = min(size.width, size.height) / 2
            irises[index].isHidden = eyeStyle != .round
            // Big pupils read friendly; a thin white rim around them looked startled.
            irises[index].bounds = CGRect(x: 0, y: 0, width: size.width * 0.56, height: size.height * 0.62)
            irises[index].cornerRadius = size.width * 0.28
            centers[index] = CGPoint(x: rect.midX, y: rect.midY)
            // "^": up from the eye's lower left to its top and down again, a bit wider than the eye.
            let width = rect.width * 1.7, height = rect.height * 0.45
            let path = CGMutablePath()
            path.move(to: CGPoint(x: rect.midX - width / 2, y: rect.midY - height / 2))
            path.addQuadCurve(to: CGPoint(x: rect.midX + width / 2, y: rect.midY - height / 2),
                              control: CGPoint(x: rect.midX, y: rect.midY + height * 1.3))
            arcs[index].path = path
            arcs[index].lineWidth = max(1.2, rect.width * 0.38)
            // Round: a soft blush below and outside each eye.
            let outward: CGFloat = index == 0 ? -1 : 1
            cheeks[index].isHidden = eyeStyle != .round
            cheeks[index].frame = CGRect(x: rect.midX + (outward * 8 - 6) * scale, y: rect.midY - (13 + 3.5) * scale,
                                         width: 12 * scale, height: 7 * scale)
        }
        if let point = spec.mouth {
            let center = layerRect(CGRect(origin: point, size: .zero)).origin
            // A short smile, and a wider, deeper one for the laugh (same kind of path, so it morphs).
            func curve(width: CGFloat, depth: CGFloat) -> CGPath {
                let path = CGMutablePath()
                path.move(to: CGPoint(x: center.x - width / 2 * scale, y: center.y))
                path.addQuadCurve(to: CGPoint(x: center.x + width / 2 * scale, y: center.y),
                                  control: CGPoint(x: center.x, y: center.y - depth * 2 * scale))
                return path
            }
            smile = curve(width: 6, depth: 1.6)
            grin = curve(width: 8, depth: 3)
            mouth.path = smile
            mouth.lineWidth = 1.4 * scale
        }
        mouth.isHidden = eyeStyle != .round || spec.mouth == nil
        apply(animated: false)
    }

    /// A double blink now and then, after a teammate's mascot sketch: the eyes close to a line twice
    /// within a 5.7 s cycle, in the window server, no timer here.
    private func blink() {
        let blink = CAKeyframeAnimation(keyPath: "transform.scale.y")
        blink.values = [1, 1, 0.08, 1, 1, 0.08, 1, 1]
        blink.keyTimes = [0, 0.40, 0.415, 0.43, 0.73, 0.745, 0.76, 1]
        blink.duration = 5.7
        blink.repeatCount = .infinity
        blink.beginTime = CACurrentMediaTime() + .random(in: 0...3)
        for pupil in pupils { pupil.add(blink, forKey: "blink") }
    }

    /// Where to look, from -1 to 1 on each axis (0: straight ahead).
    func look(_ point: CGPoint, animated: Bool = true) {
        let next = CGPoint(x: max(-1, min(1, point.x)), y: max(-1, min(1, point.y)))
        // Round: the pupils rest through small pointer moves instead of trembling after each.
        if animated, eyeStyle == .round, hypot(next.x - look.x, next.y - look.y) < 0.06 { return }
        look = next
        apply(animated: animated)
    }

    /// The eyes close into arcs for a moment (one keyframe animation, no timer).
    func laugh(for seconds: Double = 0.9) {
        guard arcs[0].animation(forKey: "laugh") == nil else { return }
        let fade = 0.12 / seconds
        func blink(_ values: [Float]) -> CAKeyframeAnimation {
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = values
            animation.keyTimes = [0, NSNumber(value: fade), NSNumber(value: 1 - fade), 1]
            animation.duration = seconds
            return animation
        }
        for pupil in pupils { pupil.add(blink([1, 0, 0, 1]), forKey: "laugh") }
        for arc in arcs { arc.add(blink([0, 1, 1, 0]), forKey: "laugh") }
        if !mouth.isHidden, let smile, let grin {
            let wider = CAKeyframeAnimation(keyPath: "path")
            wider.values = [smile, grin, grin, smile]
            wider.keyTimes = [0, NSNumber(value: fade), NSNumber(value: 1 - fade), 1]
            wider.duration = seconds
            mouth.add(wider, forKey: "laugh")
        }
    }

    private func apply(animated: Bool) {
        CATransaction.begin()
        if animated {
            // Soft and a little behind the pointer, so she seems to watch rather than snap; the
            // round eyes slower still, so the pupils drift instead of wobbling.
            CATransaction.setAnimationDuration(eyeStyle == .round ? 0.55 : 0.4)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.25, 0.8, 0.3, 1))
        } else {
            CATransaction.setDisableActions(true)
        }
        // Lines: at most 6 canvas pixels sideways and 4.5 up or down, inside the face (wider than
        // first tried). Round: the eyes shift only slightly, and the pupils travel
        // half the way to the eye's rim, which reads calm rather than wide-eyed.
        let reach = eyeStyle == .round ? CGPoint(x: 1.5, y: 1.2) : CGPoint(x: 6, y: 4.5)
        let shift = CGPoint(x: look.x * reach.x * scale, y: look.y * reach.y * scale)
        for (index, pupil) in pupils.enumerated() {
            pupil.position = CGPoint(x: centers[index].x + shift.x, y: centers[index].y + shift.y)
            let eye = pupil.bounds.size, iris = irises[index].bounds.size
            irises[index].position = CGPoint(x: eye.width / 2 + look.x * (eye.width - iris.width) / 4,
                                             y: eye.height / 2 + look.y * (eye.height - iris.height) / 4)
        }
        CATransaction.commit()
    }
}

/// Moves every visible pair of eyes: toward the pointer when it moves (called from the pointer
/// monitors, at most 30 times a second, nothing while it rests), a glance elsewhere now and then
/// while it rests, and a laugh at a click.
@MainActor
@Observable
final class GazeCenter {
    static let shared = GazeCenter()
    /// The pointer moved in the last little while: resting Tara opens her eyes (instead of her
    /// sleepy picture) and follows it; a while after it stops she dozes off again.
    private(set) var awake = false
    static let awakeFor: Duration = .seconds(25)
    /// How the eyes look (Settings › Notch › Tara's eyes); every pair changes at once.
    @ObservationIgnored var style = EyeStyle.lines {
        didSet {
            guard style != oldValue else { return }
            for view in views.allObjects { view.restyleEyes() }
        }
    }
    @ObservationIgnored private let views = NSHashTable<SpriteHostView>.weakObjects()
    @ObservationIgnored private var lastUpdate = Date.distantPast
    @ObservationIgnored private var lastMove = Date.distantPast
    @ObservationIgnored private var wander: Timer?
    @ObservationIgnored private var doze: Task<Void, Never>?

    func add(_ view: SpriteHostView) {
        views.add(view)
        view.look(at: NSEvent.mouseLocation, animated: false)
        guard wander == nil else { return }
        // A glance every few seconds while the pointer rests: she seems to be around, not frozen.
        wander = Timer.scheduledTimer(withTimeInterval: 2.6, repeats: true) { _ in
            MainActor.assumeIsolated { GazeCenter.shared.glance() }
        }
        wander?.tolerance = 0.8
    }

    func remove(_ view: SpriteHostView) {
        views.remove(view)
        if views.count == 0 {
            wander?.invalidate()
            wander = nil
        }
    }

    func pointerMoved() {
        let now = Date()
        // Awake again, and asleep again a while after the last move (one task, renewed at most once a second).
        if !awake { awake = true }
        if doze == nil || now.timeIntervalSince(lastMove) > 1 {
            doze?.cancel()
            doze = Task { [weak self] in
                try? await Task.sleep(for: Self.awakeFor)
                guard !Task.isCancelled else { return }
                self?.awake = false
            }
        }
        lastMove = now
        guard views.count > 0 else { return }
        guard now.timeIntervalSince(lastUpdate) >= 1.0 / 30 else { return }
        lastUpdate = now
        let mouse = NSEvent.mouseLocation
        for view in views.allObjects { view.look(at: mouse) }
    }

    /// A click (on the notch, the island or Tara): every pair of eyes laughs for a moment.
    func laugh() {
        for view in views.allObjects { view.laughEyes() }
    }

    /// `--preview tara-eyes`: awake, the eyes trace a slow loop as if following a pointer, and
    /// laugh twice (recordings without moving the real pointer).
    func runDemo(style demoStyle: EyeStyle? = nil) {
        awake = true
        doze?.cancel()
        lastMove = .distantFuture  // no glances in between
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            if let demoStyle { self?.style = demoStyle }
            let start = Date()
            while let self, Date().timeIntervalSince(start) < 9 {
                let t = Date().timeIntervalSince(start)
                let target = CGPoint(x: cos(t * 1.4) * 0.9, y: sin(t * 2.1) * 0.6)
                for view in self.views.allObjects { view.glance(target) }
                if abs(t - 3) < 0.02 || abs(t - 6.5) < 0.02 { self.laugh() }
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    private func glance() {
        guard Date().timeIntervalSince(lastMove) > 3 else { return }
        let target = Bool.random() ? CGPoint.zero : CGPoint(x: .random(in: -0.8...0.8), y: .random(in: -0.5...0.5))
        for view in views.allObjects { view.glance(target) }
    }
}
