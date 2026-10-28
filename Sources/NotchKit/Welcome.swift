import AppKit
import NotchCore
import SwiftUI

/// After the first onboarding: Tara leaves the notch with "Welcome to Starnotch" (skipped with
/// Reduce Motion), stays out beside it and greets the user, then shows what she found on this
/// Mac and opens the notch on it. Nothing here asks anything outside the app.
@MainActor
final class WelcomeTour {
    /// What Tara already knows on this Mac, for her first bubble.
    struct Findings {
        var agents: [String] = []
        var meetings: Int?
        var notes: String?
        var nextMeeting: (title: String, start: Date)?
    }

    private let companion: MeetingCompanion
    private let cast: AvatarCast
    var findings: () -> Findings = { Findings() }
    /// Opens the notch on the agents.
    var openNotch: () -> Void = {}
    private var overlay: NSPanel?

    init(companion: MeetingCompanion, cast: AvatarCast) {
        self.companion = companion
        self.cast = cast
    }

    /// The display with the notch (else the main one), and where her figure lands: under the
    /// notch, low enough that her tips open above her without moving her.
    private static var screen: NSScreen? { NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main }

    private static func spot(on screen: NSScreen) -> CGPoint {
        CGPoint(x: screen.frame.midX, y: screen.visibleFrame.maxY - MeetingCompanion.tipRoom)
    }

    func play() {
        guard let screen = Self.screen, !companion.isOpen else { return }
        let spot = Self.spot(on: screen)
        if Theme.reduceMotion {
            companion.comeOutForTips(figureAt: spot)
            greet()
            return
        }
        showMoment(on: screen, spot: spot) { [weak self] in
            // She is drawn at the same spot in both windows: the hand-over doesn't show.
            self?.companion.comeOutForTips(figureAt: spot)
            self?.greet()
        }
    }

    /// `--preview welcome` (the whole moment), `welcome:hello` (the greeting), `welcome:found`.
    func preview(_ name: String) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            guard let screen = Self.screen else { return }
            switch name {
            case "welcome:hello":
                companion.comeOutForTips(figureAt: Self.spot(on: screen))
                greet()
            case "welcome:found":
                companion.comeOutForTips(figureAt: Self.spot(on: screen))
                showFound()
            default:
                play()
            }
        }
    }

    // MARK: Tara's bubbles

    private func greet() {
        companion.showTip(TaraTip(
            title: Localization.string("Hi, I'm Tara"),
            text: Localization.string("I live in the notch and come out when something needs you. Want to see what I found on this Mac?"),
            primary: .init(title: Localization.string("Show me")) { [weak self] in self?.showFound() },
            secondary: .init(title: Localization.string("Later")) { [weak self] in self?.companion.closeTip() }))
    }

    private func showFound() {
        let found = findings()
        var items = found.agents
        if let meetings = found.meetings, meetings > 0 {
            items.append(meetings == 1 ? Localization.string("1 meeting in my memory")
                                       : String(format: Localization.string("%lld meetings in my memory"), meetings))
        }
        if let notes = found.notes { items.append(String(format: Localization.string("Notes: %@"), notes)) }
        if let next = found.nextMeeting {
            items.append(String(format: Localization.string("Next: %@ at %@"), next.title, TimeText.clock(next.start)))
        }
        let title = found.agents.isEmpty ? Localization.string("No agents yet") : Localization.string("Here's what I found")
        let text = found.agents.isEmpty
            ? Localization.string("When Claude Code or Codex runs, I show it in the notch and come out when it waits for you.")
            : Localization.string("I keep an eye on these. When one finishes or waits for you, I'll tell you right here.")
        companion.showTip(TaraTip(
            title: title, text: text, items: items,
            primary: .init(title: Localization.string("Open the notch")) { [weak self] in
                self?.companion.closeTip()
                Task { @MainActor in
                    // After she is back up in the notch.
                    try? await Task.sleep(for: .milliseconds(320))
                    self?.openNotch()
                }
            }))
    }

    // MARK: The brand moment

    private func showMoment(on screen: NSScreen, spot: CGPoint, then done: @escaping () -> Void) {
        let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        // Her center in the view, from the top left of the screen.
        let center = CGPoint(x: spot.x - screen.frame.minX, y: screen.frame.maxY - spot.y)
        let view = WelcomeMoment(character: cast.main, colorway: cast.colorway, center: center) { [weak self, weak panel] in
            done()
            // The companion is in front now: the moment's own figure can go.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(60))
                panel?.orderOut(nil)
                if self?.overlay === panel { self?.overlay = nil }
            }
        }
        let hosting = NSHostingView(rootView: view)
        hosting.safeAreaRegions = []
        panel.contentView = hosting
        panel.setFrame(screen.frame, display: false)
        panel.orderFrontRegardless()
        overlay = panel
    }
}

/// The screen dims a little, Tara drops out of the notch and "Welcome to Starnotch" rises under
/// her; the words and the dim fade, she stays.
private struct WelcomeMoment: View {
    let character: String
    let colorway: Colorway
    /// Her center, in this view's coordinates.
    let center: CGPoint
    let done: () -> Void
    @State private var out = false
    @State private var words = false
    @State private var dim = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(dim ? 0.42 : 0)
                .ignoresSafeArea()
            // Laid out like the floating Tara (84 × 80, figure 72 high at the bottom).
            AvatarView(character: character, mood: .idle, height: 72, colorway: colorway, emergeOnAppear: false)
                .frame(width: 84, height: 80, alignment: .bottom)
                .scaleEffect(out ? 1 : 0.7, anchor: .top)
                .offset(y: out ? 0 : -(center.y + 20))
                .position(center)
            Text("Welcome to \(Text(Brand.displayName).foregroundStyle(Theme.accent))")
                .font(.system(size: 44, weight: .semibold))
                .tracking(-0.6)
                .foregroundStyle(Color.white)
                .shadow(color: .black.opacity(0.5), radius: 20, y: 4)
                .fixedSize()
                .opacity(words ? 1 : 0)
                .offset(y: words ? 0 : 8)
                .position(x: center.x, y: center.y + 96)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .task {
            withAnimation(.easeOut(duration: 0.25)) { dim = true }
            withAnimation(.spring(duration: 0.3, bounce: 0.15)) { out = true }
            try? await Task.sleep(for: .milliseconds(180))
            withAnimation(.easeOut(duration: 0.25)) { words = true }
            try? await Task.sleep(for: .milliseconds(1700))
            withAnimation(.easeOut(duration: 0.25)) {
                words = false
                dim = false
            }
            try? await Task.sleep(for: .milliseconds(260))
            done()
        }
    }
}
