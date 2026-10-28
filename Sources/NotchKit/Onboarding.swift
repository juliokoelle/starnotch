import AppKit
import EventKit
import NotchCore
import Observation
import SwiftUI

/// First run in one calm window, one card per step: meet Tara, connect the agents, allow the
/// calendar and the players, connect meetings, choose how Tara thinks, connect the notes, pick
/// the tools. Every step can be skipped; everything is in Settings later. Nothing is set up
/// before the user's click.
@MainActor
@Observable
final class Onboarding {
    typealias Step = OnboardingStep

    private(set) var step = Step.tara
    /// The last move went forward (steps slide in from the right).
    private(set) var forward = true
    /// The setup rows show exactly what changes on disk.
    var detailed = false
    let state: AppState
    let cast: AvatarCast
    let setup: SetupCenter
    /// The Meeting module's sync: it keeps going when the window closes.
    let jamie: JamieConnect
    @ObservationIgnored var onFinish: () -> Void = {}
    @ObservationIgnored private var notesSetup: VaultSetup?
    /// Goes up each time the window comes back to the front: the calendar's state is read again
    /// (macOS doesn't announce a change made in System Settings).
    private(set) var rechecks = 0

    init(state: AppState, cast: AvatarCast, setup: SetupCenter, jamie: JamieConnect) {
        self.state = state
        self.cast = cast
        self.setup = setup
        self.jamie = jamie
        // Open at login starts off: only its own switch in the tools step turns it on.
        setup.selected.remove(.launchAtLogin)
    }

    func recheck() { rechecks += 1 }

    static var motion: Animation { Theme.reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.28, bounce: 0.1) }
    /// A step's icon turning into a check: a short pop, a plain fade with Reduce Motion.
    static var pop: Animation { Theme.reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.3, bounce: 0.4) }

    /// The Mac's own permissions get steps of their own (calendar, players) or sit with the tools
    /// (open at login); the agents step sets up everything else that was found.
    static let ownSteps: Set<SetupItem> = [.calendar, .musicAutomation, .launchAtLogin, .lidAwake]

    /// The steps this Mac shows: the players' step only with a player installed and the
    /// system-wide source not working (it needs no permission), the notes step only with the
    /// notes connector in this build. Previews show the players' step.
    var flow: OnboardingFlow {
        var hidden: Set<Step> = []
        if !setup.offered.contains(.musicAutomation) || (MediaRemoteBridge.isUsable && !setup.preview) { hidden.insert(.music) }
        if (VaultSetup.preview ?? Runtime.vault) == nil { hidden.insert(.notes) }
        return OnboardingFlow(hidden: hidden)
    }

    func go(to next: Step) {
        guard next != step else { return }
        forward = next.rawValue > step.rawValue
        withAnimation(Self.motion) { step = next }
    }

    func next() {
        if let following = flow.next(after: step) { go(to: following) } else { onFinish() }
    }

    func back() {
        if let previous = flow.previous(before: step) { go(to: previous) }
    }

    /// Claude Code is on this Mac: the subscription can do Tara's thinking.
    var claudeFound: Bool { setup.paths.claudeBinary != nil }

    /// The notes folder picker, one for the whole window.
    var notes: VaultSetup {
        if let notesSetup { return notesSetup }
        let made = VaultSetup(persists: state.persists)
        notesSetup = made
        return made
    }

    // MARK: Agents

    /// What the agents step offers, in page order.
    var agentItems: [SetupItem] { setup.offered.filter { !Self.ownSteps.contains($0) } }

    /// Switched on and not set up yet: what "Set up" would do.
    var pendingAgents: [SetupItem] {
        agentItems.filter { setup.selected.contains($0) && !setup.isSetUp($0) && setup.status[$0] == nil }
    }

    var agentsRunning: Bool { agentItems.contains { setup.status[$0] == .running } }

    // MARK: Permissions

    /// `later`: nothing to allow yet (no player was running). `writeOnly`: the calendar may only
    /// add events.
    enum Grant: Equatable { case notAsked, asking, granted, denied, later, writeOnly }

    /// Where a permission stands: the calendar as macOS has it now, the players as macOS
    /// answered this launch. Previews only know what was clicked in them.
    func grant(_ item: SetupItem) -> Grant {
        if setup.status[item] == .running { return .asking }
        if item == .musicAutomation {
            switch setup.musicPermission {
            case .allowed: return .granted
            case .denied: return .denied
            case .later: return .later
            case nil: return .notAsked
            }
        }
        if setup.preview {
            switch setup.status[item] {
            case .failed: return .denied
            case .done: return .granted
            default: return .notAsked
            }
        }
        switch item {
        case .calendar:
            _ = rechecks
            switch EKEventStore.authorizationStatus(for: .event) {
            case .notDetermined: return .notAsked
            case .fullAccess: return .granted
            case .writeOnly: return .writeOnly
            default: return .denied
            }
        default:
            return setup.isSetUp(item) ? .granted : .notAsked
        }
    }

    // MARK: Done

    /// The step's connection or permission is in place: its icon turns into a check.
    func isDone(_ step: Step) -> Bool {
        switch step {
        case .agents:
            return pendingAgents.isEmpty && !agentsRunning
                && agentItems.contains { item in
                    if case .done = setup.status[item] { return true }
                    return setup.isSetUp(item)
                }
        case .calendar:
            return grant(.calendar) == .granted
        case .music:
            return grant(.musicAutomation) == .granted
        case .meetings:
            if case .done = jamie.phase { return !jamie.phase.isEmpty }
            return false
        case .notes:
            return notes.isConnected
        case .tara, .brain, .tools:
            return false
        }
    }

    /// The step's own action was taken (granted, refused, connected or running): the footer
    /// offers Continue instead of "Skip for now".
    func isSettled(_ step: Step) -> Bool {
        switch step {
        case .calendar: return grant(.calendar) != .notAsked
        case .music: return grant(.musicAutomation) != .notAsked
        case .meetings: return isDone(.meetings) || jamie.phase.isRunning
        default: return isDone(step)
        }
    }

    /// Open at login, only when its switch in the tools step was turned on, goes in with the last click.
    func finish() {
        if setup.selected.contains(.launchAtLogin) && setup.offered.contains(.launchAtLogin)
            && !setup.isSetUp(.launchAtLogin) && setup.status[.launchAtLogin] == nil {
            setup.setUp([.launchAtLogin])
        }
        onFinish()
    }

    /// Previews: the current step as it looks right after its action.
    func previewDone() {
        switch step {
        case .agents: setup.setUp(Set(pendingAgents))
        case .calendar: setup.setUp([.calendar])
        case .music: setup.setUp([.musicAutomation])
        case .meetings: jamie.preview(.done(meetings: 42, hint: nil))
        default: break
        }
    }
}

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    let model: Onboarding
    private var window: NSWindow?
    /// Closed by its last button: the welcome may follow.
    private var finished = false
    /// The window closed, by its last button (true) or its close button.
    var onClose: ((_ finished: Bool) -> Void)?

    init(model: Onboarding) {
        self.model = model
        super.init()
        model.onFinish = { [weak self] in
            self?.finished = true
            self?.window?.close()
        }
    }

    func show(at step: Onboarding.Step? = nil) {
        if let step { model.go(to: model.flow.resolve(step)) }
        if window == nil {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: OnboardingView.size),
                                  styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            let hosting = NSHostingController(rootView: OnboardingView(model: model))
            hosting.sizingOptions = []
            window.contentViewController = hosting
            // The content runs under the transparent title bar; the frame is the whole window.
            window.setFrame(NSRect(origin: .zero, size: OnboardingView.size), display: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.title = String(format: Localization.string("Welcome to %@"), Brand.displayName)
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = .black
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            // A small screen: the window fits under the menu bar, the step scrolls, the buttons stay.
            if let visible = (window.screen ?? NSScreen.main)?.visibleFrame, visible.height - 20 < window.frame.height {
                window.setFrame(NSRect(x: window.frame.minX, y: visible.minY + 10, width: window.frame.width, height: visible.height - 20),
                                display: false)
            }
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model.recheck()
    }

    func windowWillClose(_ notification: Notification) {
        let done = finished
        finished = false
        onClose?(done)
    }
}

// MARK: - The window

struct OnboardingView: View {
    @Bindable var model: Onboarding
    /// Fits a 13" display under the menu bar; the steps scroll when they need more.
    static let size = CGSize(width: 640, height: 700)

    var body: some View {
        VStack(spacing: 0) {
            StepIndicator(model: model)
                .frame(height: 30)
                .padding(.top, 2)
            ZStack(alignment: .top) {
                page(model.step)
                    .id(model.step)
                    .transition(slide)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
            footer
        }
        // The window's height: 700, less on a small screen.
        .frame(width: Self.size.width)
        .frame(maxHeight: .infinity)
        .background(Color.black)
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .environment(\.roomyRows, true)
    }

    private var slide: AnyTransition {
        if Theme.reduceMotion { return .opacity }
        let shift: CGFloat = model.forward ? 28 : -28
        return .asymmetric(insertion: .opacity.combined(with: .offset(x: shift)),
                           removal: .opacity.combined(with: .offset(x: -shift)))
    }

    @ViewBuilder private func page(_ step: Onboarding.Step) -> some View {
        switch step {
        case .tara:
            Page(model: model, step: step, title: "Meet Tara",
                 why: "\(Brand.displayName) turns the notch into a calm place for your agents, meetings and music. Tara lives there and comes out when something needs you.") {
                TaraStep(model: model)
            }
        case .agents:
            Page(model: model, step: step, symbol: "terminal", title: "Your agents",
                 why: "See what your coding agents do and answer their requests from the notch. One click connects what \(Brand.displayName) found.",
                 stays: "Hooks and backups stay on this Mac. Settings › What's set up undoes each change.") {
                AgentsStep(model: model)
            }
        case .calendar:
            Page(model: model, step: step, symbol: "calendar", title: "Your calendar",
                 why: "Tara shows your next meeting, counts down to it and joins the call with one click.",
                 stays: "Your calendar is read on this Mac; an event is only added when you capture one.") {
                PermissionStep(model: model, item: .calendar)
            }
        case .music:
            Page(model: model, step: step, symbol: "music.note", title: "Music",
                 why: "Play, pause and skip from the notch, with the cover beside the island. macOS asks once for each player.",
                 stays: "Only needed when the system-wide source can't be read. The commands go to the player on this Mac.") {
                PermissionStep(model: model, item: .musicAutomation)
            }
        case .meetings:
            Page(model: model, step: step, symbol: "waveform", title: "Meetings",
                 why: "Tara remembers what was said in your meetings and points out contradictions, open questions and promises.",
                 stays: "Copied into Tara's memory on this Mac. With Claude as her brain, that memory goes to Anthropic when she answers or writes meeting cards.") {
                MeetingsStep(model: model)
            }
        case .brain:
            Page(model: model, step: step, symbol: "brain", title: "How Tara thinks",
                 why: "The model behind Tara's answers and meeting cards. You can change it any time.",
                 stays: "Apple Intelligence and simple rules stay on this Mac; with Claude, the text goes to Anthropic.") {
                BrainStep(model: model)
            }
        case .notes:
            Page(model: model, step: step, symbol: "books.vertical", title: "Your notes",
                 why: "An Obsidian vault or any Markdown folder: your tasks and today's note in the notch, and Tara reads along.",
                 stays: "Your notes stay in their folder. With Claude as Tara's brain, your tasks and today's note go to Anthropic when you ask her something.") {
                NotesStep(model: model)
            }
        case .tools:
            Page(model: model, step: step, symbol: "square.grid.2x2", title: "Tools",
                 why: "Switch on what you want in the notch; the rest stays out of the way. Settings › Tools has the same switches.") {
                ToolsStep(model: model)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                if model.flow.previous(before: model.step) != nil {
                    Button("Back") { model.back() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                }
                Spacer()
                primary
            }
            .font(.system(size: 14))
            // A quiet promise under every step.
            Label("Nothing changes without your click", systemImage: "lock")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .labelStyle(.titleAndIcon)
        }
        .padding(.horizontal, 40)
        .padding(.top, 14)
        .padding(.bottom, 18)
    }

    /// One accent action at a time: the step's own button while it waits ("Skip for now" beside
    /// it), Continue once it's done.
    @ViewBuilder private var primary: some View {
        let step = model.step
        let pending = model.pendingAgents
        if step == .agents && model.agentsRunning {
            primaryButton("Setting up…") {}.disabled(true)
        } else if step == .agents && !pending.isEmpty {
            skipButton
            primaryButton(pending.count == 1 ? "Set up 1 item" : "Set up \(pending.count) items") { model.setup.setUp(Set(pending)) }
        } else if step == .tools {
            primaryButton("Start using \(Brand.displayName)") { model.finish() }
        } else if [.calendar, .music, .meetings, .notes].contains(step) && !model.isSettled(step) {
            skipButton
        } else {
            primaryButton("Continue") { model.next() }
        }
    }

    private var skipButton: some View {
        Button("Skip for now") { model.next() }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .contentShape(Rectangle())
    }

    private func primaryButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(minWidth: 132)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(Theme.accent)
        .keyboardShortcut(.defaultAction)
    }
}

/// Short dots at the top, one per step: where you are; a click jumps to any step.
private struct StepIndicator: View {
    let model: Onboarding

    var body: some View {
        let steps = model.flow.steps
        let index = steps.firstIndex(of: model.step) ?? steps.firstIndex { $0.rawValue > model.step.rawValue } ?? steps.count
        HStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element) { position, step in
                let current = step == model.step
                let done = position < index
                Button { model.go(to: step) } label: {
                    // A round dot; the current one is a dash that grows out of it. Scale and
                    // opacity only, and both ends stay round at rest.
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(done ? 0.5 : 0.16))
                            .frame(width: 6, height: 6)
                            .opacity(current ? 0 : 1)
                        Capsule()
                            .fill(Theme.accent)
                            .frame(width: 18, height: 6)
                            .scaleEffect(x: current ? 1 : 6 / 18, y: 1)
                            .opacity(current ? 1 : 0)
                    }
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text(LocalizedStringKey(Self.name(step))))
                .accessibilityLabel(Text(LocalizedStringKey(Self.name(step))))
                .accessibilityAddTraits(current ? .isSelected : [])
            }
        }
        .animation(Onboarding.motion, value: model.step)
    }

    static func name(_ step: Onboarding.Step) -> String {
        switch step {
        case .tara: "Tara"
        case .agents: "Your agents"
        case .calendar: "Your calendar"
        case .music: "Music"
        case .meetings: "Meetings"
        case .brain: "How Tara thinks"
        case .notes: "Your notes"
        case .tools: "Tools"
        }
    }
}

/// A step: its icon, title, why it's asked and where the data stays, then what it asks.
private struct Page<Content: View>: View {
    let model: Onboarding
    /// The step this page shows (the model moves on while the old page slides out).
    let step: Onboarding.Step
    var symbol: String?
    let title: LocalizedStringKey
    let why: LocalizedStringKey
    var stays: LocalizedStringKey?
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 14) {
                    if let symbol {
                        StepIcon(symbol: symbol, done: model.isDone(step))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(title)
                                .font(.system(size: 26, weight: .semibold))
                                .tracking(-0.3)
                            if step.isOptional {
                                Text("Optional")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        Text(why)
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.textBody)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                        if let stays {
                            Label(stays, systemImage: "lock")
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                content()
            }
            .padding(.horizontal, 40)
            .padding(.top, 18)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        // Rows that scroll on fade out above the buttons instead of being cut.
        .mask {
            VStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 20)
            }
        }
    }
}

/// The step's symbol in its square; once the step is done, a check pops in its place.
private struct StepIcon: View {
    let symbol: String
    let done: Bool

    var body: some View {
        ZStack {
            if done {
                Circle()
                    .fill(Theme.ok)
                    .overlay {
                        Image(systemName: "checkmark")
                            .font(.system(size: 19, weight: .bold))
                            .foregroundStyle(Color.black.opacity(0.82))
                    }
                    .frame(width: 44, height: 44)
                    .transition(Theme.reduceMotion ? .opacity : .scale(scale: 0.5).combined(with: .opacity))
                    .accessibilityLabel(Text("Done"))
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 48, height: 48)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: 48, height: 48)
        .animation(Onboarding.pop, value: done)
        .onChange(of: done) { _, now in if now { Haptics.confirm() } }
    }
}

/// Rows on one card, with hairlines between them.
private struct CardList<Item: Hashable, Row: View>: View {
    let items: [Item]
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element) { index, item in
                if index > 0 { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.leading, 16) }
                row(item)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct OnboardingLabel: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary).padding(.leading, 2)
    }
}

/// Larger type for the shared rows (Jamie, tools) while they sit in onboarding.
private struct RoomyRowsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var roomyRows: Bool {
        get { self[RoomyRowsKey.self] }
        set { self[RoomyRowsKey.self] = newValue }
    }
}

// MARK: - Tara

private struct TaraStep: View {
    let model: Onboarding

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            NotchStage(cast: model.cast)
                .frame(height: 190)
            MainCharacterPicker(cast: model.cast, state: model.state, tileSize: 56, labelled: true)
        }
    }
}

/// A notch on a card, and the main character coming out of it; again when another is picked.
private struct NotchStage: View {
    let cast: AvatarCast
    @State private var shown = ""
    @State private var out = false

    var body: some View {
        let character = cast.main
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card)
            if !shown.isEmpty {
                AvatarView(character: shown, mood: .idle, height: 100, colorway: cast.colorway, emergeOnAppear: false)
                    .offset(y: out || Theme.reduceMotion ? 46 : -96)
                    .opacity(out ? 1 : 0)
            }
            UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12, style: .continuous)
                .fill(Color.black)
                .frame(width: 176, height: 32)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .task {
            shown = character
            try? await Task.sleep(for: .milliseconds(360))
            withAnimation(Onboarding.motion) { out = true }
        }
        .onChange(of: character) { _, picked in
            Task {
                withAnimation(.easeIn(duration: 0.14)) { out = false }
                try? await Task.sleep(for: .milliseconds(160))
                shown = picked
                withAnimation(Onboarding.motion) { out = true }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Agents

private struct AgentsStep: View {
    @Bindable var model: Onboarding

    var body: some View {
        let setup = model.setup
        let items = model.agentItems
        VStack(alignment: .leading, spacing: 18) {
            if setup.foundAgents.isEmpty {
                Text("No coding agents yet. \(Brand.displayName) picks up Claude Code and Codex as soon as they're installed.")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    OnboardingLabel("Found on this Mac")
                    // Up to six tools: the chips wrap onto a second line.
                    ChipFlow(spacing: 6) {
                        ForEach(setup.foundAgents) { found in
                            Label(found.name, systemImage: found.symbol)
                                .font(.system(size: 13.5, weight: .medium))
                                .lineLimit(1)
                                .fixedSize()
                                .padding(.horizontal, 10)
                                .frame(height: 30)
                                .background(Theme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
            }
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    OnboardingLabel("What gets set up")
                    CardList(items: items) { SetupItemRow(center: setup, item: $0, detailed: model.detailed) }
                }
                Button(model.detailed ? "Hide the details" as LocalizedStringKey : "Show exactly what changes") {
                    withAnimation(Onboarding.motion) { model.detailed.toggle() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.accent)
                .frame(minHeight: 28)
                .contentShape(Rectangle())
            }
        }
    }
}

// MARK: - Calendar and music

/// One permission: what it brings, in the notch's own look, and one button that asks macOS.
private struct PermissionStep: View {
    let model: Onboarding
    let item: SetupItem

    var body: some View {
        let grant = model.grant(item)
        VStack(alignment: .leading, spacing: 18) {
            NotchSample(item: item)
            Group {
                switch grant {
                case .notAsked, .asking:
                    Button { model.setup.setUp([item]) } label: {
                        HStack(spacing: 8) {
                            if grant == .asking { ProgressView().controlSize(.small) }
                            Text(item == .calendar ? "Allow calendar access" : "Allow control of your players")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.extraLarge)
                    .tint(Theme.accent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(grant == .asking)
                case .granted:
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item == .calendar ? "Calendar allowed" : "Players allowed")
                            .font(.system(size: 15, weight: .semibold))
                        Text(item == .calendar ? "Your next meeting shows in the notch, with Join one click away."
                                               : "macOS asks each player once; then play, pause and skip work from the notch.")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .later:
                    // Nothing was asked: no player was running. No check.
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No player is running")
                            .font(.system(size: 15, weight: .semibold))
                        Text("macOS asks the first time a player plays.")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .denied, .writeOnly:
                    VStack(alignment: .leading, spacing: 10) {
                        Label(grant == .writeOnly ? "\(Brand.displayName) may only add events." as LocalizedStringKey : "macOS didn't allow it.",
                              systemImage: "exclamationmark.circle")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.waiting)
                        Text(item == .musicAutomation
                             ? "Turn it on in System Settings › Privacy & Security › Automation, under \(Brand.displayName)." as LocalizedStringKey
                             : grant == .writeOnly
                             ? "Choose Full Access in System Settings › Privacy & Security › Calendars; this card follows."
                             : "Turn it on in System Settings › Privacy & Security › Calendars; this card follows.")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open System Settings") {
                            PrivacyPane.open(item == .musicAutomation ? "Privacy_Automation" : "Privacy_Calendars")
                        }
                        .controlSize(.large)
                    }
                }
            }
            .transition(.opacity)
            .animation(Onboarding.motion, value: grant)
        }
    }
}

/// What a permission brings, drawn like the island: a black pill under a notch.
private struct NotchSample: View {
    let item: SetupItem

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card)
            HStack(spacing: 10) {
                Image(systemName: item == .calendar ? "video.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 26, height: 26)
                    .background(Theme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(item == .calendar ? "Design review in 5 min" : "Night Drive")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(item == .calendar ? "Join · ⌃⌥J" : "Play, pause, skip")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(width: 300, height: 58)
            .background(Color.black, in: UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22, style: .continuous))
        }
        .frame(height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityHidden(true)
    }
}

// MARK: - Meetings

private struct MeetingsStep: View {
    @Bindable var model: Onboarding

    private enum Source { case jamie, wispr, granola }

    var body: some View {
        CardList(items: [Source.jamie, .wispr, .granola]) { source in
            switch source {
            case .jamie: JamieRow(jamie: model.jamie)
            case .wispr: ComingSoonRow(name: "Wispr Flow", symbol: "mic")
            case .granola: ComingSoonRow(name: "Granola", symbol: "note.text")
            }
        }
    }
}

// MARK: - Tara's brain

private struct BrainStep: View {
    @Bindable var model: Onboarding

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardList(items: [TaraBrain.claudeCode, .api, .apple, .rules]) { brain in
                BrainRow(model: model, brain: brain)
            }
            Text(model.state.settings.brain == .auto
                 ? "Not chosen yet: Tara uses what she finds. Settings › Meeting agent has the same choice."
                 : "Settings › Meeting agent has the same choice." as LocalizedStringKey)
                .font(.system(size: 13)).foregroundStyle(.tertiary)
                .padding(.leading, 2)
        }
    }
}

// MARK: - Notes

private struct NotesStep: View {
    let model: Onboarding

    var body: some View {
        CardList(items: [0]) { _ in NotesRow(state: model.state, setup: model.notes) }
    }
}

/// A row's symbol in its small square.
struct RowSymbol: View {
    let name: String
    var active = false

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(active ? Theme.accent : Color.secondary)
            .frame(width: 28, height: 28)
            .background(Color.primary.opacity(active ? 0.09 : 0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// Jamie in one row: connect, the sync as it runs, and what to do when it came back empty.
/// Onboarding and Settings › Meeting agent show the same row.
struct JamieRow: View {
    let jamie: JamieConnect
    @State private var copied = false
    @Environment(\.roomyRows) private var roomy

    var body: some View {
        let phase = jamie.phase
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                RowSymbol(name: "waveform", active: synced(phase))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Jamie").font(.system(size: roomy ? 15 : 13, weight: .medium))
                    status(phase)
                        .font(.system(size: roomy ? 14 : 11.5))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                action(phase)
            }
            if phase.isRunning {
                Text("Keeps going when you close this window.")
                    .font(.system(size: roomy ? 13.5 : 11.5)).foregroundStyle(.tertiary)
                    .padding(.leading, 40)
                    .transition(.opacity)
            }
            if phase.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Signed in with another Jamie account? Sign out of it on meetjamie.ai in your browser first, then use the other account here.")
                        .font(.system(size: roomy ? 13.5 : 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Use another account") { jamie.useAnotherAccount() }
                }
                .padding(.leading, 40)
                .transition(.opacity)
            }
        }
        .animation(Onboarding.motion, value: phase)
        // uv installed in Terminal meanwhile: the row turns into Connect by itself.
        .task {
            jamie.checkBlocker()
            while jamie.blocker == .noUV && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                jamie.checkBlocker()
            }
        }
    }

    private func synced(_ phase: JamieConnect.Phase) -> Bool {
        if case .done = phase { return !phase.isEmpty }
        return false
    }

    @ViewBuilder private func status(_ phase: JamieConnect.Phase) -> some View {
        switch (jamie.blocker, phase) {
        case (.noAgent, _):
            Text("This build has no meeting agent.").foregroundStyle(.secondary)
        case (.noUV, _):
            Text("Needs uv, a small Python tool; then connect.").foregroundStyle(.secondary)
        case (_, .idle):
            Text("Your recorded meetings become Tara's memory.").foregroundStyle(.secondary)
        case (_, .connecting):
            Text("Connecting…").foregroundStyle(.secondary)
        case (_, .login):
            Text("Sign in to Jamie in your browser.").foregroundStyle(.secondary)
        case (_, .syncing(let count, let title)):
            Text(count == 1 ? "1 meeting · \(title)" as LocalizedStringKey : "\(count) meetings · \(title)").foregroundStyle(.secondary)
        case (_, .done(let meetings, _)) where phase.isEmpty:
            Label(meetings == 0 ? "No meetings in this Jamie account" as LocalizedStringKey : "This Jamie account looks empty", systemImage: "exclamationmark.circle")
                .foregroundStyle(Theme.waiting)
        case (_, .done(let meetings, _)):
            Label(meetings == 1 ? "1 meeting from Jamie" as LocalizedStringKey : "\(meetings) meetings from Jamie", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Theme.ok)
        case (_, .failed(let why)):
            Text(Localization.string(why)).foregroundStyle(Theme.waiting)
        }
    }

    @ViewBuilder private func action(_ phase: JamieConnect.Phase) -> some View {
        switch (jamie.blocker, phase) {
        case (.noAgent, _):
            EmptyView()
        case (.noUV, _):
            Button(copied ? "Copied: paste it into Terminal" as LocalizedStringKey : "Install uv") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(MeetingAgentSetup.uvInstallCommand, forType: .string)
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
                copied = true
            }
            .help(MeetingAgentSetup.uvInstallCommand)
        case (_, .connecting), (_, .syncing):
            ProgressView().controlSize(.small)
        case (_, .login):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Button("Open again") { jamie.openLogin() }
            }
        case (_, .failed):
            Button("Try again") { jamie.connect() }
        case (_, .done):
            if phase.isEmpty {
                EmptyView()
            } else {
                Button("Sync again") { jamie.connect() }
                    .buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: roomy ? 13.5 : 12))
                    .frame(minHeight: 28)
            }
        case (_, .idle):
            Button(jamie.hasLogin ? "Sync now" as LocalizedStringKey : "Connect") { jamie.connect() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
        }
    }
}

/// A meeting source that isn't there yet: greyed, no button.
private struct ComingSoonRow: View {
    let name: String
    let symbol: String

    var body: some View {
        HStack(spacing: 12) {
            RowSymbol(name: symbol)
            Text(name).font(.system(size: 15, weight: .medium))
            Spacer(minLength: 12)
            Text("Coming soon").font(.system(size: 13.5)).foregroundStyle(.tertiary)
        }
        .opacity(0.5)
        .accessibilityElement(children: .combine)
    }
}

/// One way for Tara to think, picked like a radio button.
private struct BrainRow: View {
    @Bindable var model: Onboarding
    let brain: TaraBrain
    @State private var key = MeetingAgentSetup.keys()["ANTHROPIC_API_KEY"] ?? ""
    @State private var apple: AppleModelStatus?

    var body: some View {
        let selected = model.state.settings.brain == brain
        // Apple Intelligence stays open while it's off or downloading: the user can still switch it on.
        let blocked = brain == .claudeCode && !model.claudeFound
            || brain == .apple && (apple == .notSupported || apple == .unknown)
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Haptics.tick()
                withAnimation(Onboarding.motion) { model.state.settings.brain = brain }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(selected ? Theme.accent : Color.secondary)
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(LocalizedStringKey(BrainInfo.title(brain))).font(.system(size: 15, weight: .medium))
                            if brain == .claudeCode && model.claudeFound {
                                Text("Recommended")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Theme.accent)
                                    .padding(.horizontal, 6)
                                    .frame(height: 19)
                                    .background(Theme.accent.opacity(0.14), in: Capsule())
                            }
                        }
                        Text(LocalizedStringKey(!blocked ? BrainInfo.line(brain)
                                                : brain == .apple ? "Needs Apple Intelligence on this Mac."
                                                : "Needs Claude Code on this Mac."))
                            .font(.system(size: 14)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(blocked)
            .opacity(blocked ? 0.5 : 1)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .task { if brain == .apple { apple = await MeetingAgentSetup.appleStatus() } }
            if brain == .api && selected {
                SecureField("Anthropic API key", text: $key, prompt: Text("sk-ant-…"))
                    .textFieldStyle(.roundedBorder)
                    // Previews never write the real agent.env.
                    .onChange(of: key) { _, value in if model.state.persists { MeetingAgentSetup.setKey("ANTHROPIC_API_KEY", value) } }
                    .padding(.leading, 40)
                    .transition(.opacity)
            }
        }
    }
}

/// The words for each way Tara thinks, shared with Settings › Meeting agent.
enum BrainInfo {
    static func title(_ brain: TaraBrain) -> String {
        switch brain {
        case .auto: "Automatic"
        case .claudeCode: "Claude subscription"
        case .api: "Own API key"
        case .apple: "Apple Intelligence (on this Mac, free)"
        case .rules: "Simple rules"
        }
    }

    static func line(_ brain: TaraBrain) -> String {
        switch brain {
        case .auto: "Claude Code when it's there, else an API key, else Apple Intelligence, else simple rules."
        case .claudeCode: "Runs through Claude Code on your plan; no API credits."
        case .api: "Your Anthropic key, billed per use."
        case .apple: "Apple's model on this Mac, free; simpler answers than Claude."
        case .rules: "No model. Works offline and catches the obvious."
        }
    }
}

// MARK: - Tools

private struct ToolsStep: View {
    let model: Onboarding

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if model.setup.offered.contains(.launchAtLogin) {
                VStack(alignment: .leading, spacing: 8) {
                    OnboardingLabel("When your Mac starts")
                    CardList(items: [SetupItem.launchAtLogin]) { SetupItemRow(center: model.setup, item: $0) }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                OnboardingLabel("In the notch")
                CardList(items: ToolSwitches.tabs.map(ToolItem.module)) { ToolRow(item: $0, state: model.state) }
            }
            VStack(alignment: .leading, spacing: 8) {
                OnboardingLabel("Small tools")
                CardList(items: ToolFeature.allCases.map(ToolItem.feature)) { ToolRow(item: $0, state: model.state) }
            }
        }
    }
}

/// Lays chips out left to right and wraps them onto the next line when the row is full. A chip
/// wider than the row gets the row's width (a chip that truncates then ends in "…").
struct ChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = Self.size(of: subviews[index], within: bounds.width)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(width: CGFloat, subviews: Subviews) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        for index in subviews.indices {
            let size = Self.size(of: subviews[index], within: width)
            if var last = rows.last, last.width + spacing + size.width <= width {
                last.indices.append(index)
                last.width += spacing + size.width
                last.height = max(last.height, size.height)
                rows[rows.count - 1] = last
            } else {
                rows.append(([index], size.width, size.height))
            }
        }
        return rows
    }

    private static func size(of subview: LayoutSubview, within width: CGFloat) -> CGSize {
        let natural = subview.sizeThatFits(.unspecified)
        guard natural.width > width else { return natural }
        return subview.sizeThatFits(ProposedViewSize(width: width, height: natural.height))
    }
}
