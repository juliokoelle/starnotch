import AppKit
import NotchCore
import SwiftUI

/// The Dashboard's tokens: dark first like the onboarding window, correct in light mode. Neutrals
/// carry a trace of blue so they don't read as flat grey. One accent, Tara's colour as the user
/// picked it (`TaraAccent`), for selection and action; status colours only where a state means
/// something (amber for overdue).
enum DashboardStyle {
    @MainActor static var accent: Color { TaraAccent.current }
    /// Text on the accent: dark on a light colour (Mint, Sol), white otherwise.
    @MainActor static var onAccent: Color { TaraAccent.shared.isLight ? Color.black.opacity(0.82) : .white }

    /// The window behind the content.
    static let background = dynamic(dark: rgb(0.059, 0.062, 0.072), light: rgb(0.962, 0.963, 0.970))
    static let sidebar = dynamic(dark: rgb(0.078, 0.081, 0.094), light: rgb(0.930, 0.932, 0.943))
    /// A card: a little lighter than the window in dark mode, white in light mode.
    static let card = dynamic(dark: NSColor(white: 1, alpha: 0.045), light: .white)
    static let cardHover = dynamic(dark: NSColor(white: 1, alpha: 0.07), light: rgb(0.982, 0.983, 0.988))
    static let hairline = dynamic(dark: NSColor(white: 1, alpha: 0.065), light: NSColor(white: 0, alpha: 0.075))
    /// Inset fills inside a card (bars, chips, empty heatmap cells).
    static let well = dynamic(dark: NSColor(white: 1, alpha: 0.055), light: NSColor(red: 0.1, green: 0.12, blue: 0.2, alpha: 0.05))
    static let selection = dynamic(dark: NSColor(white: 1, alpha: 0.08), light: NSColor(red: 0.1, green: 0.12, blue: 0.2, alpha: 0.07))
    /// A switch that is off.
    static let switchOff = dynamic(dark: NSColor(white: 1, alpha: 0.16), light: NSColor(white: 0, alpha: 0.12))

    static let cardRadius: CGFloat = 16
    static let gutter: CGFloat = 20

    /// Short and calm: at most 220 ms, a fade with Reduce Motion.
    static var motion: Animation { Theme.reduceMotion ? .easeOut(duration: 0.12) : .easeOut(duration: 0.22) }

    private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    private static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

// MARK: - Controls (Settings use them too)

struct DashboardCapsuleStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .lineLimit(1)
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .dashboardGlass(prominent ? .accent : .plain, in: Capsule())
            .scaleEffect(configuration.isPressed && !Theme.reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : enabled ? 1 : 0.45)
            .animation(DashboardStyle.motion, value: configuration.isPressed)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .fixedSize()
    }
}

// MARK: - Glass

/// The one material for the Dashboard's controls: Liquid Glass on macOS 26 and later (tinted with
/// Tara's colour where something is chosen or is the main action), a soft fill with a light edge
/// before that. No heavy borders.
enum DashboardGlass { case plain, accent, clear }

extension View {
    @ViewBuilder func dashboardGlass<S: Shape>(_ kind: DashboardGlass, in shape: S) -> some View {
        if kind == .accent {
            // See-through glass with a breath of Tara's colour, like Apple Music's buttons; filled
            // with the colour itself it was loud. A drawn wash, not a glass tint, so it stays
            // when the window isn't in front (system glass turns grey then).
            background(DashboardStyle.accent.opacity(0.24), in: shape)
                .overlay(shape.fill(LinearGradient(colors: [Color.white.opacity(0.12), .clear], startPoint: .top, endPoint: .center))
                    .allowsHitTesting(false))
                .overlay(shape.stroke(LinearGradient(colors: [Color.white.opacity(0.28), Color.white.opacity(0.04)],
                                                     startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
        } else if #available(macOS 26, *) {
            switch kind {
            case .clear: glassEffect(.clear.interactive(), in: shape)
            default: glassEffect(.regular.interactive(), in: shape)
            }
        } else {
            background(kind == .accent ? AnyShapeStyle(DashboardStyle.accent) : AnyShapeStyle(DashboardStyle.well), in: shape)
                .overlay(shape.stroke(LinearGradient(colors: [Color.white.opacity(kind == .accent ? 0.35 : 0.14), .clear],
                                                     startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
        }
    }

    /// The Dashboard's switch and glass buttons everywhere below (Settings' forms too).
    func dashboardControls() -> some View { modifier(DashboardControls()) }
}

private struct DashboardControls: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.toggleStyle(TaraSwitchStyle()).buttonStyle(ClearGlassButton())
        } else {
            content.toggleStyle(TaraSwitchStyle())
        }
    }
}

/// System glass without the window's tint: see-through like Apple Music's buttons. Filled with
/// Tara's colour the buttons were loud and their labels hard to read; the colour stays for the
/// switches and what is chosen.
@available(macOS 26, *)
private struct ClearGlassButton: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(configuration).buttonStyle(.glass).tint(nil)
    }
}

/// Choose one of a few values: glass capsules on one glass track, the chosen one in Tara's colour.
/// The same look for Home's period and the choices in Settings.
/// `label` names the choice for VoiceOver, which hears it as one picker; ← and → move between
/// the options while one of them has the keyboard focus.
struct GlassSegmented<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    @Namespace private var pill
    @FocusState private var focused: Int?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let chosen = option.value == selection
                Button {
                    withAnimation(DashboardStyle.motion) { selection = option.value }
                } label: {
                    Text(option.title)
                        .font(.system(size: 13, weight: chosen ? .semibold : .medium))
                        .monospacedDigit()
                        .lineLimit(1)
                        .foregroundStyle(chosen ? Color.primary : Color.primary.opacity(0.7))
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background {
                            if chosen {
                                Capsule().fill(Color.clear)
                                    .dashboardGlass(.accent, in: Capsule())
                                    .matchedGeometryEffect(id: "chosen", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .focused($focused, equals: index)
            }
        }
        .padding(3)
        .dashboardGlass(.plain, in: Capsule())
        .fixedSize()
        .onKeyPress(.leftArrow) { step(-1) }
        .onKeyPress(.rightArrow) { step(1) }
        .accessibilityRepresentation {
            Picker(label, selection: $selection) {
                ForEach(options.indices, id: \.self) { index in
                    Text(options[index].title).tag(options[index].value)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    /// The option beside the chosen one; the focus follows it.
    private func step(_ offset: Int) -> KeyPress.Result {
        guard let current = options.firstIndex(where: { $0.value == selection }) else { return .ignored }
        let next = current + offset
        guard options.indices.contains(next) else { return .handled }
        withAnimation(DashboardStyle.motion) { selection = options[next].value }
        focused = next
        return .handled
    }
}

/// A switch in Tara's colour that stays in colour when the window isn't in front (the system
/// switch turns grey then). In a form its label lays out like the system one.
struct TaraSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        LabeledContent {
            TaraSwitch(isOn: configuration.isOn) { configuration.isOn.toggle() }
        } label: {
            configuration.label
        }
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

/// A button underneath, so it takes the keyboard focus and Space toggles it.
private struct TaraSwitch: View {
    let isOn: Bool
    let toggle: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button {
            withAnimation(Theme.reduceMotion ? nil : .spring(duration: 0.22, bounce: 0.25)) { toggle() }
        } label: {
            track
        }
        .buttonStyle(.plain)
        .animation(Theme.reduceMotion ? nil : .spring(duration: 0.22, bounce: 0.25), value: isOn)
    }

    private var track: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? AnyShapeStyle(DashboardStyle.accent.gradient) : AnyShapeStyle(DashboardStyle.switchOff))
                .overlay(Capsule().strokeBorder(Color.white.opacity(isOn ? 0.18 : 0.06), lineWidth: 0.5))
            Circle()
                .fill(.white)
                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                .padding(2)
        }
        .frame(width: 38, height: 22)
        .opacity(enabled ? 1 : 0.45)
        .contentShape(Capsule())
    }
}
