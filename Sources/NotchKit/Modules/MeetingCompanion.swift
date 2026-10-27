import AppKit
import NotchCore
import Observation
import SwiftUI

/// The main character popped out of the notch for a meeting: a small window that floats above
/// everything, and each new meeting card as a speech bubble beside it. Dragged back up to the
/// notch, or closed, it goes back.
@MainActor
@Observable
final class MeetingCompanion: NSObject {
    struct Bubble: Identifiable, Equatable {
        let id: Int
        let kind: MeetingCard.Kind
        let text: String
    }

    private(set) var bubbles: [Bubble] = []
    private(set) var isOpen = false
    /// The meeting is running: the character listens.
    var listening = false

    @ObservationIgnored let cast: AvatarCast
    /// A click on a bubble opens the full card in the notch.
    @ObservationIgnored var onOpenCard: (Int) -> Void = { _ in }
    @ObservationIgnored private var panel: NSPanel?
    private static let originKey = "meetingCompanionOrigin"
    private static let size = CGSize(width: 300, height: 260)
    /// The figure's center, from the window's bottom right corner (padding 8, figure 84 × 80).
    private static let figure = CGPoint(x: 50, y: 48)

    init(cast: AvatarCast) {
        self.cast = cast
    }

    func open() {
        guard panel == nil else { return }
        let panel = NSPanel(contentRect: CGRect(origin: savedOrigin(), size: Self.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        let hosting = NSHostingView(rootView: CompanionView(companion: self))
        hosting.safeAreaRegions = []
        panel.contentView = hosting
        panel.orderFrontRegardless()
        self.panel = panel
        isOpen = true
    }

    /// Dragged out of the notch: opens under the pointer and follows it until let go.
    func follow(ended: Bool) {
        if panel == nil { open() }
        let mouse = NSEvent.mouseLocation
        // The figure sits at the bottom right of the window: keep it under the pointer.
        panel?.setFrameOrigin(CGPoint(x: mouse.x - Self.size.width + Self.figure.x, y: mouse.y - Self.figure.y))
        if ended { endDrag() }
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        bubbles = []
        isOpen = false
    }

    /// A new meeting card: a bubble for a few seconds, at most three at a time.
    func show(_ entry: MeetingModule.Entry) {
        guard isOpen else { return }
        let bubble = Bubble(id: entry.id, kind: entry.card.kind, text: entry.card.detail ?? entry.card.title)
        withAnimation(Theme.reduceMotion ? nil : Theme.snappy) {
            bubbles.append(bubble)
            if bubbles.count > 3 { bubbles.removeFirst() }
        }
        // One sleep per bubble, nothing while no bubble shows.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self else { return }
            withAnimation(Theme.reduceMotion ? nil : Theme.close) { self.bubbles.removeAll { $0.id == bubble.id } }
        }
    }

    // MARK: Position

    private func savedOrigin() -> CGPoint {
        if let saved = UserDefaults.standard.array(forKey: Self.originKey) as? [Double], saved.count == 2 {
            let point = CGPoint(x: saved[0], y: saved[1])
            if NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -40, dy: -40).contains(point) }) { return point }
        }
        // First time: below the notch (the built-in display), a little to the right.
        let notched = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
        let screen = notched?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return CGPoint(x: screen.midX + 120, y: screen.maxY - Self.size.height - 40)
    }

    // MARK: Dragging (SwiftUI content doesn't move a borderless window by itself)

    @ObservationIgnored private var dragStart: (mouse: CGPoint, origin: CGPoint)?

    func drag() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        if dragStart == nil { dragStart = (mouse, panel.frame.origin) }
        guard let start = dragStart else { return }
        panel.setFrameOrigin(CGPoint(x: start.origin.x + mouse.x - start.mouse.x, y: start.origin.y + mouse.y - start.mouse.y))
    }

    func endDrag() {
        dragStart = nil
        guard let panel else { return }
        let frame = panel.frame
        // Let go up at the notch (the pointer in the menu bar, near the middle): back into it.
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? panel.screen,
           mouse.y >= screen.visibleFrame.maxY - 24, abs(mouse.x - screen.frame.midX) < 260 {
            Haptics.confirm()
            close()
            return
        }
        UserDefaults.standard.set([Double(frame.origin.x), Double(frame.origin.y)], forKey: Self.originKey)
    }
}

private struct CompanionView: View {
    let companion: MeetingCompanion
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Spacer(minLength: 0)
            ForEach(companion.bubbles) { bubble in
                BubbleView(bubble: bubble) { companion.onOpenCard(bubble.id) }
                    .transition(Theme.reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
            }
            HStack(alignment: .bottom, spacing: 4) {
                if hovering {
                    Button { companion.close() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 20, height: 20)
                            .background(Color.black.opacity(0.75), in: Circle())
                    }
                    .buttonStyle(PressScale())
                    .help("Back to the notch")
                    .transition(.opacity)
                }
                AvatarView(character: companion.cast.main, mood: companion.listening ? .listening : .idle,
                           height: 72, colorway: companion.cast.colorway, emergeOnAppear: false)
                    .frame(width: 84, height: 80, alignment: .bottom)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                        .onChanged { _ in companion.drag() }
                        .onEnded { _ in companion.endDrag() })
                    .help("Drag to move; let go at the notch to put it back")
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

private struct BubbleView: View {
    let bubble: MeetingCompanion.Bubble
    let action: () -> Void

    var body: some View {
        let tint = MeetingStyle.tint(bubble.kind)
        Button(action: action) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: MeetingStyle.symbol(bubble.kind))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(tint)
                Text(bubble.text)
                    .font(Theme.font(12, .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: 260, alignment: .leading)
            .background(Color.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.7), lineWidth: 1.2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .help("Open the full card")
    }
}
