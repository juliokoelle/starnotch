import SwiftUI

/// A loop as a tiny round face with two eyes (the avatar sprites are too soft at 12 to 14 pt).
/// Open eyes: healthy; closed lines: resting; a badge when something is up.
struct AgentFace: View {
    enum Mood: Equatable {
        case working
        /// Done with its turn, waiting for the user.
        case waiting
        case idle
        case failed
    }

    var color: Color
    var mood: Mood
    var size: CGFloat
    var showsBadge = true

    @State private var blink = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            sphere
            eyes
        }
        .frame(width: size, height: size)
        .overlay(alignment: .topLeading) {
            if showsBadge { badge.offset(x: -size * 0.06, y: -size * 0.04) }
        }
        .task(id: mood) { await blinkLoop() }
        .accessibilityHidden(true)
    }

    private var sphere: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [color.blended(with: .white, by: 0.45), color, color.blended(with: .black, by: 0.35)],
                    center: UnitPoint(x: 0.34, y: 0.28),
                    startRadius: 0,
                    endRadius: size * 0.78
                )
            )
            .overlay(
                // A soft rim of light along the top edge gives the sphere its depth.
                Circle()
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.45), .clear], startPoint: .top, endPoint: .center),
                        lineWidth: max(0.5, size * 0.025)
                    )
            )
            .saturation(mood == .idle || mood == .failed ? 0.55 : 1)
            .brightness(mood == .idle ? -0.08 : 0)
    }

    @ViewBuilder private var eyes: some View {
        let ink = Color.black.opacity(0.82)
        if mood == .working || mood == .waiting {
            HStack(spacing: size * 0.17) {
                ForEach(0..<2, id: \.self) { _ in
                    Capsule()
                        .fill(ink)
                        .frame(width: size * 0.12, height: size * 0.27)
                        .scaleEffect(y: blink ? 0.12 : 1)
                }
            }
            .offset(y: -size * 0.02)
        } else {
            HStack(spacing: size * 0.13) {
                ForEach(0..<2, id: \.self) { _ in
                    Capsule()
                        .fill(ink)
                        .frame(width: size * 0.17, height: max(1, size * 0.055))
                }
            }
            .offset(y: size * 0.04)
        }
    }

    @ViewBuilder private var badge: some View {
        let diameter = max(7, size * 0.36)
        switch mood {
        case .working:
            ZStack {
                Circle().fill(Theme.accent)
                if diameter >= 12 { BusyDots(diameter: diameter) }
            }
            .frame(width: diameter, height: diameter)
            .overlay(Circle().strokeBorder(.black, lineWidth: max(1, diameter * 0.12)))
        case .waiting:
            Circle().fill(Theme.waiting)
                .frame(width: diameter * 0.7, height: diameter * 0.7)
                .overlay(Circle().strokeBorder(.black, lineWidth: max(1, diameter * 0.1)))
        case .failed:
            Circle().fill(Theme.critical)
                .frame(width: diameter * 0.7, height: diameter * 0.7)
                .overlay(Circle().strokeBorder(.black, lineWidth: max(1, diameter * 0.1)))
        case .idle:
            EmptyView()
        }
    }

    private func blinkLoop() async {
        guard mood == .working || mood == .waiting, !reduceMotion, size >= 14 else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: 2.6...5.8)))
            withAnimation(.easeIn(duration: 0.07)) { blink = true }
            try? await Task.sleep(for: .milliseconds(110))
            withAnimation(.easeOut(duration: 0.12)) { blink = false }
        }
    }
}

/// Three white dots in the busy badge, breathing in sequence.
private struct BusyDots: View {
    let diameter: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: diameter * 0.08) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(.white)
                        .frame(width: diameter * 0.17, height: diameter * 0.17)
                        .opacity(reduceMotion ? 1 : 0.45 + 0.55 * max(0, sin(t * 4.2 - Double(index) * 0.9)))
                }
            }
        }
    }
}

extension Color {
    /// Linear blend in sRGB.
    func blended(with other: Color, by amount: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let b = NSColor(other).usingColorSpace(.sRGB) ?? .black
        return Color(
            .sRGB,
            red: a.redComponent + (b.redComponent - a.redComponent) * amount,
            green: a.greenComponent + (b.greenComponent - a.greenComponent) * amount,
            blue: a.blueComponent + (b.blueComponent - a.blueComponent) * amount,
            opacity: a.alphaComponent
        )
    }
}
