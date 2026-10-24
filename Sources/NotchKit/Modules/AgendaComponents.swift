import AppKit
import NotchCore
import SwiftUI

// Shared pieces for the calendar and Today modules.

/// Initials in a soft circle tinted with the person's identity color.
struct InitialsAvatar: View {
    let name: String
    var size: CGFloat = 22

    var initials: String {
        let words = name.replacingOccurrences(of: "(", with: "").split(separator: " ")
        return String(words.prefix(2).compactMap(\.first)).uppercased()
    }

    var body: some View {
        let tint = Theme.identity(for: name)
        Text(initials)
            .font(Theme.font(size * 0.4, .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.18), in: Circle())
            .overlay(Circle().strokeBorder(Color.black, lineWidth: size > 24 ? 0 : 1.5))
    }
}

/// Overlapping avatars, at most `limit`.
struct AvatarStack: View {
    let names: [String]
    var size: CGFloat = 22
    var limit = 3

    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(Array(names.prefix(limit).enumerated()), id: \.offset) { _, name in
                InitialsAvatar(name: name, size: size)
            }
        }
    }
}

/// Minutes left as a ring: quiet until fifteen minutes before, then the accent with a soft glow.
struct CountdownRing: View {
    let start: Date
    let end: Date
    let now: Date
    var size: CGFloat = 46
    var color: Color = Theme.accent
    /// Ears: the ring alone.
    var showsLabel = true

    var body: some View {
        let until = start.timeIntervalSince(now)
        let running = until <= 0 && now < end
        let progress: Double = running
            ? 1 - end.timeIntervalSince(now) / max(end.timeIntervalSince(start), 1)
            : max(0, min(1, 1 - until / 3600))
        let awake = until <= 15 * 60
        ZStack {
            Circle().stroke(Color.white.opacity(0.08), lineWidth: size < 24 ? 2.2 : 3)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(awake ? color : Theme.textSecondary, style: StrokeStyle(lineWidth: size < 24 ? 2.2 : 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: awake ? color.opacity(0.6) : .clear, radius: 5)
                .animation(Theme.snappy, value: progress)
            VStack(spacing: -1) {
                if !showsLabel {
                    EmptyView()
                } else if running {
                    Text("now").font(Theme.font(10.5, .semibold)).foregroundStyle(Theme.textPrimary)
                } else if until < 3600 {
                    Text("\(Int((until / 60).rounded(.up)))")
                        .font(Theme.font(size * 0.33, .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                        .contentTransition(.numericText())
                    Text("min").font(Theme.font(9)).foregroundStyle(Theme.textSecondary)
                } else {
                    Text(TimeText.clock(start)).font(Theme.font(11, .semibold).monospacedDigit()).foregroundStyle(Theme.textBody)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

/// Seven small columns: meetings per day this week, today in the accent.
struct WeekGlance: View {
    let counts: [Int]
    let today: Int
    var notes: [Int: String] = [:]
    var height: CGFloat = 16

    private let letters = ["M", "T", "W", "T", "F", "S", "S"]

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(0..<7, id: \.self) { index in
                let count = counts[index]
                VStack(spacing: 3) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.white.opacity(0.05))
                            .frame(width: 7, height: height)
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(fill(index))
                            .frame(width: 7, height: max(2, height * CGFloat(min(count, 5)) / 5))
                            .shadow(color: index == today ? Theme.accent.opacity(0.7) : .clear, radius: 4)
                    }
                    .overlay(alignment: .top) {
                        if notes[index] != nil {
                            Circle().fill(Theme.textBody).frame(width: 3, height: 3).offset(y: -6)
                        }
                    }
                    Text(letters[index])
                        .font(Theme.font(9.5, index == today ? .semibold : .regular))
                        .foregroundStyle(index == today ? Theme.textPrimary : Theme.textTertiary)
                }
                .help(notes[index].map { "\(count) meetings · \($0)" } ?? "\(count) meetings")
            }
        }
    }

    private func fill(_ index: Int) -> Color {
        if index == today { return Theme.accent }
        return index < today ? Color.white.opacity(0.16) : Color.white.opacity(0.34)
    }
}

/// Diagonal stripes for focus bands: quiet, clearly not a meeting.
struct Hatch: View {
    var color: Color
    var spacing: CGFloat = 5

    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += spacing
            }
            context.stroke(path, with: .color(color), lineWidth: 1)
        }
    }
}

/// A link in running text: neutral, light, fine underline (never the accent).
struct QuietLink: View {
    let title: String
    var symbol = "arrow.up.right"
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title).underline(true, color: Theme.textSecondary.opacity(hovering ? 0.9 : 0.4))
                Image(systemName: symbol).font(.system(size: 8.5, weight: .semibold))
            }
            .font(Theme.font(12, .medium))
            .foregroundStyle(hovering ? Theme.textPrimary : Theme.textBody)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
    }
}

/// The one action of a meeting with a link. Small, in the accent, with its key.
struct JoinPill: View {
    let link: MeetingLink
    var key = "↵"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text("Join")
                Text(key).font(Theme.font(11, .medium)).foregroundStyle(.white.opacity(0.65))
            }
            .font(Theme.font(12.5, .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: Theme.accent.opacity(0.45), radius: 8, y: 2)
        }
        .buttonStyle(PressScale())
        .help("Join on \(link.provider.displayName) (⌃⌥J)")
    }
}

extension MeetingLink.Provider {
    var displayName: String {
        switch self {
        case .meet: "Google Meet"
        case .zoom: "Zoom"
        case .teams: "Teams"
        }
    }
}

// MARK: Confirm: "Leise Symbole"

/// Animates a stroke drawing in when `active` turns on.
private struct DrawIn: ViewModifier {
    let active: Bool
    @State private var drawn = false

    func body(content: Content) -> some View {
        content
            .mask(alignment: .leading) {
                Rectangle().scaleEffect(x: (active && !drawn) ? 0.001 : 1, anchor: .leading)
            }
            .onAppear {
                guard active, !Theme.reduceMotion else { drawn = true; return }
                withAnimation(.easeOut(duration: 0.24).delay(0.06)) { drawn = true }
            }
    }
}

struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.05))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return p
    }
}

// MARK: Toast

/// A small section label: sentence case, quiet.
struct SectionLabel: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(Theme.font(11.5, .semibold)).foregroundStyle(Theme.textSecondary)
            if let trailing {
                Text(trailing).font(Theme.font(11.5).monospacedDigit()).foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Soft glow around the active element.
extension View {
    func activeGlow(_ on: Bool, color: Color = Theme.accent, radius: CGFloat = 14) -> some View {
        background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(color.opacity(on ? 0.10 : 0))
                .shadow(color: color.opacity(on ? 0.35 : 0), radius: radius)
        }
    }
}
