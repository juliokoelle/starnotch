import AppKit
import SwiftUI

/// Design tokens for the notch. One accent (blue) for action, selection and live work;
/// status tints only where a state means something; identity colors only on agent faces.
enum Theme {
    static let accent = Color(hex: 0x4C8DFF)

    static let ok = Color(hex: 0x4CC38A)
    static let waiting = Color(hex: 0xE9A23B)
    static let critical = Color(hex: 0xF0645A)

    static let textPrimary = Color.white.opacity(0.94)
    static let textBody = Color(hex: 0xDCDCE1)
    static let textSecondary = Color.white.opacity(0.52)
    static let textTertiary = Color.white.opacity(0.30)

    /// Cards sit a little lighter than the black island, without borders.
    static let card = Color.white.opacity(0.055)
    static let cardHover = Color.white.opacity(0.085)

    /// Agent identities, assigned by a stable hash of the project.
    static let identities: [Color] = [
        Color(hex: 0x45C7B4),  // teal
        Color(hex: 0xF0705C),  // coral
        Color(hex: 0xF3A23F),  // amber
        Color(hex: 0x8F76F6),  // violet
        Color(hex: 0x62A8FF),  // sky
        Color(hex: 0xE674A8),  // rose
    ]

    static func identity(for key: String) -> Color {
        // djb2, stable across launches (unlike Hasher).
        var hash: UInt64 = 5381
        for byte in key.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return identities[Int(hash % UInt64(identities.count))]
    }

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    // MARK: Motion

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Opening (peek and panel): response 0.42, damping 0.8, one slight overshoot.
    static var open: Animation { reduceMotion ? .easeOut(duration: 0.18) : .spring(response: 0.42, dampingFraction: 0.8) }
    /// Back into the notch: response 0.45, critically damped, never bounces.
    static var close: Animation { reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.45, dampingFraction: 1.0) }
    /// Hover peek.
    static var peek: Animation { reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.36, bounce: 0.18) }
    /// Tabs, selection, content swaps.
    static var snappy: Animation { reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.3, bounce: 0.12) }
}

extension Color {
    /// The same colour turned around the colour wheel, like `.hueRotation` on a view.
    func hueShifted(_ degrees: Double) -> Color {
        guard degrees != 0, let ns = NSColor(self).usingColorSpace(.sRGB) else { return self }
        var hue = ns.hueComponent + degrees / 360
        hue -= floor(hue)
        return Color(nsColor: NSColor(hue: hue, saturation: ns.saturationComponent, brightness: ns.brightnessComponent, alpha: ns.alphaComponent))
    }

    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

/// Content entering or leaving: fades, un-blurs and slides a few points, like the Dynamic Island.
struct BlurSlide: ViewModifier {
    var blur: CGFloat
    var x: CGFloat
    var y: CGFloat
    var scale: CGFloat
    var opacity: Double

    func body(content: Content) -> some View {
        content
            .blur(radius: blur)
            .scaleEffect(scale, anchor: .top)
            .offset(x: x, y: y)
            .opacity(opacity)
    }
}

extension AnyTransition {
    static func blurSlide(x: CGFloat = 0, y: CGFloat = 0, scale: CGFloat = 1) -> AnyTransition {
        if Theme.reduceMotion { return .opacity }
        return .modifier(
            active: BlurSlide(blur: 8, x: x, y: y, scale: scale, opacity: 0),
            identity: BlurSlide(blur: 0, x: 0, y: 0, scale: 1, opacity: 1)
        )
    }
}

enum Haptics {
    static func tick() { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    static func open() { NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now) }
    static func confirm() { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
}
