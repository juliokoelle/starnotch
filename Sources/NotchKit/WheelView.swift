import AppKit
import NotchCore
import SwiftUI

/// Full-screen transparent canvas with the wheel positioned under the notch.
struct WheelCanvas: View {
    let model: WheelModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.clear
            WheelView(model: model)
                .frame(width: WheelMetrics.diameter, height: WheelMetrics.diameter)
                // Grows out of the notch; with Reduce Motion it only fades.
                .scaleEffect(model.isPresented || reduceMotion ? 1 : 0.4, anchor: .top)
                .offset(y: model.isPresented || reduceMotion ? 0 : -WheelMetrics.gapBelowNotch * 2)
                .opacity(model.isPresented ? 1 : 0)
                .position(model.center)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }
}

struct WheelView: View {
    let model: WheelModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            BlurBackground(diameter: WheelMetrics.diameter)
            Circle().fill(Color.black.opacity(0.52))

            highlightSector
            dividers

            ForEach(SlotPosition.allCases, id: \.self) { position in
                SlotView(
                    slot: model.slots[position],
                    isActive: model.activeSlot == position,
                    isHighlighted: model.highlighted == position
                )
                .offset(x: position.direction.dx * WheelMetrics.slotRadius,
                        y: -position.direction.dy * WheelMetrics.slotRadius)
            }

            hub

            Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.35), radius: 28, y: 14)
        .animation(reduceMotion ? .easeOut(duration: 0.1) : .spring(response: 0.26, dampingFraction: 0.82),
                   value: model.highlighted)
        .animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.82),
                   value: model.highlightAngle)
    }

    private var highlightSector: some View {
        ZStack {
            SectorShape(innerRadius: WheelMetrics.hubRadius + 3, outerRadius: WheelMetrics.radius - 3)
                .fill(
                    RadialGradient(
                        colors: [Theme.accent.opacity(0.10), Theme.accent.opacity(0.42)],
                        center: .center,
                        startRadius: WheelMetrics.hubRadius,
                        endRadius: WheelMetrics.radius
                    )
                )
            SectorShape(innerRadius: WheelMetrics.radius - 6, outerRadius: WheelMetrics.radius - 3)
                .fill(Theme.accent)
        }
        .rotationEffect(.degrees(model.highlightAngle))
        .opacity(model.highlighted == nil ? 0 : 1)
    }

    private var dividers: some View {
        ForEach(0..<4, id: \.self) { index in
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1, height: WheelMetrics.radius - WheelMetrics.hubRadius - 10)
                .offset(y: -(WheelMetrics.radius + WheelMetrics.hubRadius) / 2)
                .rotationEffect(.degrees(45 + Double(index) * 90))
        }
    }

    private var hub: some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.45))
            Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            VStack(spacing: 2) {
                Text(hubTitle)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(hubSubtitle)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: WheelMetrics.hubRadius * 2 - 14)
            .contentTransition(.opacity)
        }
        .frame(width: WheelMetrics.hubRadius * 2, height: WheelMetrics.hubRadius * 2)
    }

    private var hubTitle: String {
        if let highlighted = model.highlighted, let slot = model.slots[highlighted] {
            return slot.name
        }
        return model.slots.isEmpty ? "No apps" : "Cancel"
    }

    private var hubSubtitle: String {
        if let highlighted = model.highlighted {
            if highlighted == model.activeSlot { return "Active" }
            return model.mode == .hold ? "Release" : "Click"
        }
        if model.slots.isEmpty { return "Open Settings" }
        return model.mode == .hold ? "Release here" : "Esc"
    }
}

private struct SlotView: View {
    let slot: WheelModel.Slot?
    let isActive: Bool
    let isHighlighted: Bool

    var body: some View {
        VStack(spacing: 5) {
            if let slot {
                if let icon = slot.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: WheelMetrics.iconSize, height: WheelMetrics.iconSize)
                        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                } else {
                    Image(systemName: slot.symbol ?? "circle")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(isHighlighted ? Color.white : Theme.textBody)
                        .frame(width: 40, height: 40)
                        .background(Color.white.opacity(isHighlighted ? 0.16 : 0.08), in: Circle())
                        .frame(width: WheelMetrics.iconSize, height: WheelMetrics.iconSize)
                }
                Text(slot.name)
                    .font(.system(size: 11, weight: isHighlighted ? .semibold : .medium))
                    .foregroundStyle(isHighlighted ? Color.primary : Color.primary.opacity(0.78))
                    .lineLimit(1)
                    .frame(maxWidth: 86)
            } else {
                Circle()
                    .strokeBorder(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .frame(width: 34, height: 34)
                    .frame(width: WheelMetrics.iconSize, height: WheelMetrics.iconSize)
                Text("Empty")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            Circle()
                .fill(Theme.accent)
                .frame(width: 5, height: 5)
                .opacity(isActive ? 1 : 0)
        }
        .scaleEffect(isHighlighted ? 1.1 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// A 90 degree ring segment pointing up; rotate it to reach the other slots.
struct SectorShape: Shape {
    var innerRadius: CGFloat
    var outerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        // SwiftUI angles: 0 = right, clockwise in a y-down space. Up is -90.
        let start = Angle.degrees(-135)
        let end = Angle.degrees(-45)
        var path = Path()
        path.addArc(center: center, radius: outerRadius, startAngle: start, endAngle: end, clockwise: false)
        path.addArc(center: center, radius: innerRadius, startAngle: end, endAngle: start, clockwise: true)
        path.closeSubpath()
        return path
    }
}

/// Behind-window blur (the material menus and HUDs use), masked to a circle.
private struct BlurBackground: NSViewRepresentable {
    let diameter: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        view.maskImage = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
