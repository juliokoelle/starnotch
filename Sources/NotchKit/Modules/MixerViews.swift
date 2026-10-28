import AppKit
import NotchCore
import SwiftUI

/// Where the mixer button sits, so the mixer can float next to it.
struct MixerButtonAnchor: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// The mixer's button beside the output: three sliders, 28 pt like the output button.
struct MixerButton: View {
    @Binding var open: Bool

    var body: some View {
        Button {
            withAnimation(Theme.snappy) { open.toggle() }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(open ? Theme.accent : Theme.textSecondary)
                .frame(width: 32, height: 28)
                .background(Color.white.opacity(open ? 0.1 : 0.06), in: Capsule())
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .help("Volume per app")
        .accessibilityLabel("Volume per app")
        .anchorPreference(key: MixerButtonAnchor.self, value: .bounds) { $0 }
    }
}

/// The floating mixer: one row per app that makes sound (and per app with a level set), its
/// icon, name, a slider from mute to 150 % and the level. Grows upward from the button like the
/// output list; a click elsewhere in the card closes it.
struct MixerPopover: View {
    let mixer: AppVolumeMixer
    let button: CGRect
    let container: CGSize
    let done: () -> Void

    static let width: CGFloat = 320
    static let row: CGFloat = 32
    private static let inset: CGFloat = 6
    private static let margin: CGFloat = 6

    init(mixer: AppVolumeMixer, button: CGRect, in container: CGSize, done: @escaping () -> Void) {
        self.mixer = mixer
        self.button = button
        self.container = container
        self.done = done
    }

    var body: some View {
        let rows = max(1, mixer.apps.count) + (mixer.denied ? 1 : 0)
        let frame = Self.frame(rows: rows, button: button, container: container)
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture(perform: done)
            content
                .padding(Self.inset)
                .frame(width: frame.width, height: frame.height, alignment: .top)
                .background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
                .offset(x: frame.minX, y: frame.minY)
                .transition(.scale(scale: 0.94, anchor: .bottomTrailing).combined(with: .opacity))
        }
        .frame(width: container.width, height: container.height, alignment: .topLeading)
    }

    /// Lower right corner just past the button's, growing upward, clamped into the card.
    static func frame(rows: Int, button: CGRect, container: CGSize) -> CGRect {
        let height = min(2 * inset + CGFloat(rows) * row, container.height - 2 * margin)
        let maxX = min(button.maxX + 4, container.width - margin)
        let maxY = min(button.maxY + 4, container.height - margin)
        return CGRect(x: max(margin, maxX - width), y: max(margin, maxY - height), width: width, height: height)
    }

    private var content: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                if mixer.denied {
                    Button { mixer.openPrivacySettings() } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "lock").font(.system(size: 11, weight: .semibold)).frame(width: 20)
                            Text("Allow System Audio Recording").font(Theme.font(12.5)).lineLimit(1)
                            Spacer(minLength: 4)
                            Image(systemName: "arrow.up.forward").font(.system(size: 9, weight: .bold))
                        }
                        .foregroundStyle(Theme.waiting)
                        .padding(.horizontal, 6)
                        .frame(height: Self.row)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScale())
                }
                if mixer.apps.isEmpty {
                    Text("No app is playing sound")
                        .font(Theme.font(12.5))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: Self.row)
                }
                ForEach(mixer.apps) { app in
                    MixerRow(app: app, mixer: mixer)
                }
            }
        }
        .scrollIndicators(.never)
    }
}

private struct MixerRow: View {
    let app: AppVolume.App
    let mixer: AppVolumeMixer

    var body: some View {
        let level = mixer.level(app.bundleID)
        let muted = level <= 0.001
        HStack(spacing: 8) {
            // A click on the icon mutes the app, another brings it back.
            Button { mixer.toggleMute(app.bundleID) } label: {
                ZStack(alignment: .bottomTrailing) {
                    if let icon = PlayerBridge.icon(forApp: app.bundleID) {
                        Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                            .opacity(muted ? 0.4 : 1)
                    }
                    if muted {
                        Image(systemName: "speaker.slash.fill")
                            .font(.system(size: 7.5, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                            .padding(2)
                            .background(Color(white: 0.2), in: Circle())
                            .offset(x: 3, y: 3)
                    }
                }
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScale())
            .help(muted ? "Unmute" : "Mute")
            .accessibilityLabel(muted ? "Unmute" : "Mute")

            Text(PlayerBridge.name(forApp: app.bundleID))
                .font(Theme.font(12.5))
                .foregroundStyle(app.isPlaying ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
                .frame(width: 96, alignment: .leading)

            LevelSlider(level: level) { mixer.set($0, for: app.bundleID) }
                .accessibilityLabel(Text(PlayerBridge.name(forApp: app.bundleID)))

            Text(LocalizedStringKey(AppVolume.label(level)))
                .font(Theme.font(11, .medium).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 4)
        .frame(height: MixerPopover.row)
    }
}

/// A thin level line the height of the row (28 pt to hit): white up to 100 %, the accent past it,
/// a hairline mark at 100 %. A click or drag anywhere along it sets the level.
private struct LevelSlider: View {
    let level: Double
    let set: (Double) -> Void
    @State private var dragging = false

    var body: some View {
        GeometryReader { proxy in
            let range = AppVolume.range
            let width = proxy.size.width
            let fraction = (level - range.lowerBound) / (range.upperBound - range.lowerBound)
            let full = (1 - range.lowerBound) / (range.upperBound - range.lowerBound)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                Capsule().fill(level > 1.001 ? Theme.accent : Color.white.opacity(0.8))
                    .frame(width: width * fraction)
                Rectangle().fill(Color.white.opacity(0.35))
                    .frame(width: 1, height: 7)
                    .offset(x: width * full)
            }
            .frame(height: 3)
            .scaleEffect(x: 1, y: dragging ? 1.7 : 1)
            .animation(Theme.snappy, value: dragging)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    dragging = true
                    let x = min(1, max(0, value.location.x / max(1, width)))
                    set(range.lowerBound + x * (range.upperBound - range.lowerBound))
                }
                .onEnded { _ in dragging = false })
        }
        .frame(height: 28)
        .accessibilityElement()
        .accessibilityValue(Text(LocalizedStringKey(AppVolume.label(level))))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: set(level + 0.1)
            case .decrement: set(level - 0.1)
            @unknown default: break
            }
        }
    }
}
