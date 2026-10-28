import SwiftUI

/// Small physical answers from the characters: a figure leans and bobs when the pointer touches it
/// or the peek opens (staggered), Tara squashes while pressed and hops when let go, and lands with
/// a little bounce when dropped. Transform only, springs that settle within about 200 ms, nothing
/// with Reduce Motion, and never in the way of a click.
private struct FigureCueKey: EnvironmentKey {
    static let defaultValue = 0
}

private struct FigureOrderKey: EnvironmentKey {
    static let defaultValue = 0
}

private struct HandlePressedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Goes up by one each time the peek opens: every figure on the island nudges once.
    var figureCue: Int {
        get { self[FigureCueKey.self] }
        set { self[FigureCueKey.self] = newValue }
    }

    /// A figure's place in a row (0 = Tara): its nudge waits `order` × 50 ms.
    var figureOrder: Int {
        get { self[FigureOrderKey.self] }
        set { self[FigureOrderKey.self] = newValue }
    }

    /// The closed island is being pressed: Tara, its handle, squashes.
    var handlePressed: Bool {
        get { self[HandlePressedKey.self] }
        set { self[HandlePressedKey.self] = newValue }
    }
}

/// Lean and bob once on hover and on each `figureCue`.
struct FigureNudge: ViewModifier {
    var enabled = true
    @Environment(\.figureCue) private var cue
    @Environment(\.figureOrder) private var order
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var up = false
    @State private var task: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            // Neighbours lean opposite ways, so a row reads as a little wave, not a march.
            .rotationEffect(.degrees(up ? (order.isMultiple(of: 2) ? -4 : 4) : 0), anchor: .bottom)
            .offset(y: up ? -2.5 : 0)
            .onHover { inside in if inside { nudge(after: 0) } }
            .onChange(of: cue) { nudge(after: Double(order) * 0.05) }
    }

    private func nudge(after delay: Double) {
        guard enabled, !reduceMotion else { return }
        task?.cancel()
        task = Task { @MainActor in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            withAnimation(.spring(duration: 0.09, bounce: 0)) { up = true }
            try? await Task.sleep(for: .milliseconds(90))
            withAnimation(.spring(duration: 0.18, bounce: 0.35)) { up = false }
        }
    }
}

/// Squash while pressed, a small hop when let go.
struct PressSquash: ViewModifier {
    var pressed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hop = false

    func body(content: Content) -> some View {
        let squash = pressed && !reduceMotion
        content
            .scaleEffect(x: squash ? 1.1 : 1, y: squash ? 0.86 : 1, anchor: .bottom)
            .offset(y: hop ? -5 : 0)
            .animation(.spring(duration: 0.16, bounce: 0.2), value: squash)
            .onChange(of: pressed) { was, now in
                guard was, !now, !reduceMotion else { return }
                Task { @MainActor in
                    withAnimation(.spring(duration: 0.1, bounce: 0)) { hop = true }
                    try? await Task.sleep(for: .milliseconds(100))
                    withAnimation(.spring(duration: 0.2, bounce: 0.4)) { hop = false }
                }
            }
    }
}

/// Squashes with the island's press (`handlePressed`): for Tara in the ears.
private struct HandleSquash: ViewModifier {
    @Environment(\.handlePressed) private var pressed

    func body(content: Content) -> some View {
        content.modifier(PressSquash(pressed: pressed))
    }
}

/// Touches down: flattened for a moment, then springs back up with one small overshoot.
struct LandingBounce: ViewModifier {
    var trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flat = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: flat ? 1.12 : 1, y: flat ? 0.84 : 1, anchor: .bottom)
            .onChange(of: trigger) {
                guard !reduceMotion else { return }
                Task { @MainActor in
                    withAnimation(.spring(duration: 0.07, bounce: 0)) { flat = true }
                    try? await Task.sleep(for: .milliseconds(70))
                    withAnimation(.spring(duration: 0.22, bounce: 0.45)) { flat = false }
                }
            }
    }
}

extension View {
    /// Tara as the island's handle: squashes while the closed island is pressed.
    func handleSquash() -> some View { modifier(HandleSquash()) }
}
