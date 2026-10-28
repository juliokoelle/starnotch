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
    /// Goes up each time she is put down somewhere (not back in the notch): a little landing bounce.
    private(set) var landings = 0

    @ObservationIgnored let cast: AvatarCast
    /// A click on a bubble opens the full card in the notch.
    @ObservationIgnored var onOpenCard: (Int) -> Void = { _ in }
    /// Ask Tara: her question bubble shows beside her while it's open; a click on her opens it.
    @ObservationIgnored var ask: AskTara?
    /// The question bubble takes the keyboard; not for screenshots and previews (`--capturable`, `--preview`).
    @ObservationIgnored var takesKeyboard = true
    @ObservationIgnored var onTapFigure: (() -> Void)?
    /// Let go somewhere other than the notch (Ask Tara: on a window, to ask about it); AppKit coordinates.
    @ObservationIgnored var onDrop: ((CGPoint) -> Void)?
    /// She came out only to be asked: she goes back when the question bubble closes.
    @ObservationIgnored private var outForAsk = false
    /// Where she stood before the bubble pushed her into the screen; she goes back there when it closes.
    @ObservationIgnored private var originBeforeAsk: CGPoint?
    @ObservationIgnored private var panel: FreePanel?
    private static let originKey = "meetingCompanionOrigin"
    private static let size = CGSize(width: 300, height: 260)
    /// With the question bubble: room beside her for the bubble, whose answer card grows up to
    /// about 60 % of the screen's height before it scrolls (plus the field below it).
    private static func askSize(on screen: NSScreen?) -> CGSize {
        let height = (screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        return CGSize(width: AskTaraView.width + 128, height: (height * 0.6).rounded() + 120)
    }
    /// Less room above her than this, and she moves down for the bubble instead of it shrinking.
    private static let askMinHeight: CGFloat = 420
    /// The figure's center, from the window's bottom right corner (padding 8, figure 84 × 80).
    private static let figure = CGPoint(x: 50, y: 48)

    init(cast: AvatarCast) {
        self.cast = cast
    }

    func open() {
        guard panel == nil else {
            outForAsk = false  // asked to stay out (a meeting): she stays when the question bubble closes
            return
        }
        let panel = FreePanel(contentRect: CGRect(origin: savedOrigin(), size: Self.size),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Above the menu bar, so she can be carried all the way up into the notch.
        panel.level = .statusBar
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

    /// Pulled out of the notch: opens under the pointer and follows it until the button comes up,
    /// anywhere on screen (the notch's own window stops getting the drag once the pointer leaves it).
    func beginFollow() {
        guard followMonitors.isEmpty else { return }
        if panel == nil { open() }
        moveToPointer()
        let mask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp]
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.followed(event) }
            return event
        }) {
            followMonitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.followed(event) }
        }) {
            followMonitors.append(global)
        }
    }

    @ObservationIgnored private var followMonitors: [Any] = []

    private func followed(_ event: NSEvent) {
        guard !followMonitors.isEmpty else { return }
        guard event.type == .leftMouseUp else { return moveToPointer() }
        followMonitors.forEach(NSEvent.removeMonitor)
        followMonitors = []
        endDrag()
    }

    private func moveToPointer() {
        let mouse = NSEvent.mouseLocation
        // The figure sits at the bottom right of the window: keep it under the pointer.
        let width = panel?.frame.width ?? Self.size.width
        panel?.setFrameOrigin(CGPoint(x: mouse.x - width + Self.figure.x, y: mouse.y - Self.figure.y))
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        bubbles = []
        isOpen = false
        outForAsk = false
        ask?.close()
    }

    // MARK: Ask Tara

    /// The question bubble opens: she comes out if she isn't, the window grows to the left and up
    /// around her (she stays where she is) and takes the keyboard without activating the app.
    func showAsk() {
        if panel == nil {
            open()
            outForAsk = true
        }
        guard let panel else { return }
        if panel.frame.size == Self.size { originBeforeAsk = panel.frame.origin }
        resize(panel, to: Self.askSize(on: panel.screen))
        guard takesKeyboard else { return panel.orderFrontRegardless() }
        panel.acceptsKey = true
        panel.makeKeyAndOrderFront(nil)
    }

    func hideAsk() {
        guard let panel else { return }
        panel.acceptsKey = false
        if outForAsk {
            outForAsk = false
            close()
            return
        }
        // resignKey() only notifies; out and back in hands the keyboard back to the app in front.
        if panel.isKeyWindow {
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
        if let origin = originBeforeAsk {
            panel.setFrame(CGRect(origin: origin, size: Self.size), display: true)
        } else {
            resize(panel, to: Self.size)
        }
        originBeforeAsk = nil
    }

    private func resize(_ panel: NSPanel, to size: CGSize) {
        let frame = panel.frame
        guard frame.size != size else { return }
        // The figure sits at the bottom right: keep that corner where it is, unless the bigger window
        // would leave the screen at the top or the left. At the top the bubble takes the room there
        // is (at least `askMinHeight`, else she moves down just as far); at the left she moves in.
        var target = CGRect(x: frame.maxX - size.width, y: frame.minY, width: size.width, height: size.height)
        if size.width > frame.width || size.height > frame.height,
           let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
            if size != Self.size { target.size.height = min(size.height, max(Self.askMinHeight, visible.maxY - target.minY)) }
            target.origin.y -= max(0, target.maxY - visible.maxY)
            target.origin.x += max(0, visible.minX - target.minX)
        }
        panel.setFrame(target, display: true)
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
        originBeforeAsk = nil  // moved by hand: she stays where she was put
        guard let panel else { return }
        // Saved as if the bubble were closed: the next time she comes out at the same place.
        let frame = panel.frame.size != Self.size
            ? CGRect(x: panel.frame.maxX - Self.size.width, y: panel.frame.minY, width: Self.size.width, height: Self.size.height)
            : panel.frame
        // Let go up at the notch (the pointer in the menu bar, near the middle): back into it.
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? panel.screen,
           mouse.y >= screen.visibleFrame.maxY - 24, abs(mouse.x - screen.frame.midX) < 260 {
            Haptics.confirm()
            // She slips up into the notch and fades, so the way back is seen to the end.
            let target = CGPoint(x: screen.frame.midX - Self.size.width + Self.figure.x,
                                 y: screen.frame.maxY - Self.figure.y + 30)
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Theme.reduceMotion ? 0 : 0.28
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().setFrameOrigin(target)
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.close() }
            })
            return
        }
        UserDefaults.standard.set([Double(frame.origin.x), Double(frame.origin.y)], forKey: Self.originKey)
        landings += 1
        onDrop?(mouse)
    }
}

/// A panel macOS doesn't push back below the menu bar. It takes the keyboard only while Tara is
/// asked something, so a click on her or a card never steals typing from the app in front.
private final class FreePanel: NSPanel {
    var acceptsKey = false
    override var canBecomeKey: Bool { acceptsKey }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private struct CompanionView: View {
    let companion: MeetingCompanion
    @State private var hovering = false
    @GestureState private var pressing = false

    var body: some View {
        let asking = companion.ask?.isOpen == true
        VStack(alignment: .trailing, spacing: 6) {
            Spacer(minLength: 0)
            // While she's asked something, her answer takes the cards' place.
            if !asking {
                ForEach(companion.bubbles) { bubble in
                    BubbleView(bubble: bubble) { companion.onOpenCard(bubble.id) }
                        .transition(Theme.reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                }
            }
            // Ahead of the spacer, so the answer card can take all the height the window has.
            HStack(alignment: .bottom, spacing: 4) {
                if let ask = companion.ask, asking {
                    AskTaraView(ask: ask)
                        .padding(.bottom, 10)
                        .transition(.opacity)
                }
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
                AvatarView(character: companion.cast.main,
                           mood: companion.ask?.mood ?? (companion.listening ? .listening : .idle),
                           height: 72, colorway: companion.cast.colorway, emergeOnAppear: false)
                    .modifier(PressSquash(pressed: pressing))
                    .modifier(LandingBounce(trigger: companion.landings))
                    .frame(width: 84, height: 80, alignment: .bottom)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                        .onChanged { _ in companion.drag() }
                        .onEnded { _ in companion.endDrag() })
                    // Squashed while held still; picked up (moving) she springs back with a hop.
                    .simultaneousGesture(DragGesture(minimumDistance: 0).updating($pressing) { value, state, _ in
                        state = abs(value.translation.width) + abs(value.translation.height) < 3
                    })
                    .simultaneousGesture(TapGesture().onEnded { companion.onTapFigure?() })
                    .help(Localization.string(companion.onTapFigure == nil ? "Drag to move; let go at the notch to put it back"
                                                                           : "Click to ask Tara; drag to move, let go at the notch to put it back"))
            }
            .layoutPriority(1)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(Theme.snappy, value: asking)
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
