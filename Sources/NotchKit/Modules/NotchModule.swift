import NotchCore
import SwiftUI

/// A module of the notch: what it shows beside the notch at rest, in the hover peek and in the
/// expanded panel. The shell (`NotchController`, `NotchRootView`) owns layout, motion and input;
/// a module only provides views and state. A later notch (Staffel, PANDA) reuses the shell with
/// its own modules.
@MainActor
protocol NotchModule: AnyObject {
    var kind: ModuleKind { get }
    /// SF Symbol for the tab and the wheel.
    var symbol: String { get }
    /// Small number on the tab (e.g. working agents); `nil` hides it.
    var count: Int? { get }
    /// How much the module wants to sit beside the notch while nothing is hovered:
    /// 0 = not at all, higher wins. Dictation 40, meeting soon 30, agents at work 20,
    /// music 15, a failed loop 10.
    var ambientPriority: Int { get }
    /// Height of the expanded body.
    var bodyHeight: CGFloat { get }
    /// Width of the expanded panel: modules ask for what their content needs and the island
    /// animates between sizes. Default `NotchLayout.expandedWidth`, the largest.
    var bodyWidth: CGFloat { get }

    /// Left of the hardware notch, at rest and in the peek. `peek` is true while hovered.
    func leadingEar(peek: Bool) -> AnyView
    /// Right of the hardware notch.
    func trailingEar(peek: Bool) -> AnyView
    /// The one line under the notch while hovered.
    func peekLine() -> AnyView
    /// The expanded panel body.
    func body() -> AnyView
    /// Return key, or selection from the wheel.
    func primaryAction()
    /// The panel became visible or hidden (start or stop expensive work).
    func setExpanded(_ expanded: Bool)
    /// ← or Esc while the panel is open: step back inside the module. `false` = nothing to undo.
    func handleBack() -> Bool
    /// Width of each ear at rest; default `NotchLayout.earWidth`.
    var compactEarWidth: CGFloat { get }
    /// Keys the module handles itself while expanded (↑↓ through items); `true` consumes the key.
    func handleKey(_ press: KeyPress) -> Bool
    /// A detail card or popover is open: the panel doesn't collapse when the pointer leaves.
    var holdsOpen: Bool { get }
    /// Something here needs the user (waiting for them, a failure, a meeting about to start,
    /// dictation listening): only then do the ears show at rest by default.
    var needsAttention: Bool { get }
}

extension NotchModule {
    var count: Int? { nil }
    var ambientPriority: Int { 0 }
    func setExpanded(_ expanded: Bool) {}
    func handleBack() -> Bool { false }
    var compactEarWidth: CGFloat { NotchLayout.earWidth }
    var bodyWidth: CGFloat { NotchLayout.minExpandedWidth }
    func handleKey(_ press: KeyPress) -> Bool { false }
    var holdsOpen: Bool { false }
    var needsAttention: Bool { false }
}

/// Shared between the shell and modules: the namespace for figures that travel between the
/// ear, the peek line and the panel.
struct NotchEnvironment {
    var namespace: Namespace.ID?
}

private struct NotchEnvironmentKey: EnvironmentKey {
    static let defaultValue = NotchEnvironment()
}

private struct FiguresHiddenKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var notch: NotchEnvironment {
        get { self[NotchEnvironmentKey.self] }
        set { self[NotchEnvironmentKey.self] = newValue }
    }

    /// Watch mode: no character anywhere on the island, text only. The figures return with it off.
    var figuresHidden: Bool {
        get { self[FiguresHiddenKey.self] }
        set { self[FiguresHiddenKey.self] = newValue }
    }
}

extension View {
    /// `matchedGeometryEffect` when the shell provided a namespace.
    @ViewBuilder func notchMatched(_ id: String, in namespace: Namespace.ID?, isSource: Bool = true) -> some View {
        if let namespace {
            matchedGeometryEffect(id: id, in: namespace, isSource: isSource)
        } else {
            self
        }
    }
}

/// A card inside the expanded panel: a little lighter than the black, no border.
struct NotchCard<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// A plain button that brightens its background on hover.
struct HoverRow<Label: View>: View {
    var cornerRadius: CGFloat = 12
    var tint: Color = .white
    var restOpacity: Double = 0
    var hoverOpacity: Double = 0.07
    var help: String = ""
    let action: () -> Void
    @ViewBuilder var label: Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label
                .contentShape(Rectangle())
                .background(
                    tint.opacity(hovering ? hoverOpacity : restOpacity),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
        }
        .buttonStyle(PressScale())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
        .help(help)
    }
}

/// Presses sink slightly and spring back.
struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !Theme.reduceMotion ? 0.97 : 1)
            .animation(.spring(duration: 0.22, bounce: 0.3), value: configuration.isPressed)
    }
}

enum TimeText {
    static func clock(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    /// `today`, `yesterday` or `18.10.` for a `YYYY-MM-DD` day.
    static func day(_ day: String, now: Date = Date()) -> String {
        if day == AgentScanner.day(now) { return "today" }
        if day == AgentScanner.day(now.addingTimeInterval(-86_400)) { return "yesterday" }
        let parts = day.split(separator: "-")
        return parts.count == 3 ? "\(parts[2]).\(parts[1])." : day
    }
}
