import AppKit
import NotchCore
import SwiftUI

/// One line the closed island shows for a moment.
struct Sneak: Hashable {
    enum Visual: Hashable {
        /// A character in a mood, with its project colour (hue shift).
        case character(String, AvatarMood, hue: Double)
        case symbol(String, tint: SneakTint)
        /// Album cover (Now Playing).
        case cover(NSImage)
        /// A tiny neutral dot: text first (Watch mode and its summary).
        case dot
    }

    enum SneakTint: String, Hashable, Sendable {
        case accent, ok, waiting, critical, neutral

        var color: Color {
            switch self {
            case .accent: Theme.accent
            case .ok: Theme.ok
            case .waiting: Theme.waiting
            case .critical: Theme.critical
            case .neutral: Theme.textBody
            }
        }
    }

    var visual: Visual
    var title: String
    var detail: String?
    /// Seconds on screen.
    var duration: Double = 2.6
    /// Optional click target (meeting link, hub page).
    var url: URL?
}

/// The line under the notch while a sneak shows.
struct SneakLine: View {
    let sneak: Sneak
    let cast: AvatarCast?
    @Environment(\.figuresHidden) private var figuresHidden

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if figuresHidden || sneak.visual == .dot {
                // Watch mode: text with a tiny neutral dot, no character, cover or tinted badge.
                Circle()
                    .fill(Theme.textSecondary)
                    .frame(width: 5, height: 5)
                    .padding(.bottom, 13)
            } else {
                visual
            }
            // The title stays whole; the detail shows only when it fits whole too.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    title.fixedSize()
                    if let detail = sneak.detail { self.detail(detail).fixedSize() }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 0) { title.fixedSize(); Spacer(minLength: 0) }
                HStack(spacing: 0) { title; Spacer(minLength: 0) }
            }
            .lineLimit(1)
            .padding(.bottom, 9)
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private var title: some View {
        Text(sneak.title).font(Theme.font(13, .semibold)).foregroundStyle(Theme.textPrimary)
    }

    private func detail(_ text: String) -> some View {
        Text(text).font(Theme.font(12.5)).foregroundStyle(Theme.textSecondary)
    }

    @ViewBuilder private var visual: some View {
        switch sneak.visual {
        case .character(let id, let mood, let hue):
            AvatarView(character: id, mood: mood, height: 32, colorway: Colorway(hue: hue))
                .frame(width: 38, height: 34, alignment: .bottom)
        case .cover(let image):
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(.bottom, 5)
        case .symbol(let name, let tint):
            Image(systemName: name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint.color)
                .frame(width: 28, height: 28)
                .background(tint.color.opacity(0.16), in: Circle())
                .padding(.bottom, 4)
        case .dot:
            EmptyView()
        }
    }
}
