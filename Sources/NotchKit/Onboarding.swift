import AppKit
import NotchCore
import Observation
import SwiftUI

/// First run in one calm window: meet Tara, connect the agents, meetings and Tara's brain, pick
/// the tools. Every step can be skipped; everything is in Settings later. Nothing is set up
/// before the user's click.
@MainActor
@Observable
final class Onboarding {
    enum Step: Int, CaseIterable {
        case tara, agents, meetings, tools

        var name: String {
            switch self {
            case .tara: "Tara"
            case .agents: "Your agents"
            case .meetings: "Meetings"
            case .tools: "Tools"
            }
        }
    }

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

    init(state: AppState, cast: AvatarCast, setup: SetupCenter, jamie: JamieConnect) {
        self.state = state
        self.cast = cast
        self.setup = setup
        self.jamie = jamie
    }

    static var motion: Animation { Theme.reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.28, bounce: 0.1) }

    func go(to next: Step) {
        guard next != step else { return }
        forward = next.rawValue > step.rawValue
        withAnimation(Self.motion) { step = next }
    }

    func next() {
        if let following = Step(rawValue: step.rawValue + 1) { go(to: following) } else { onFinish() }
    }

    func back() {
        if let previous = Step(rawValue: step.rawValue - 1) { go(to: previous) }
    }

    /// Claude Code is on this Mac: the subscription can do Tara's thinking.
    var claudeFound: Bool { setup.paths.claudeBinary != nil }
}

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    let model: Onboarding
    private var window: NSWindow?
    /// The window closed, by its last button or its close button.
    var onClose: (() -> Void)?

    init(model: Onboarding) {
        self.model = model
        super.init()
        model.onFinish = { [weak self] in self?.window?.close() }
    }

    func show(at step: Onboarding.Step? = nil) {
        if let step { model.go(to: step) }
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
            window.title = "Welcome to \(Brand.displayName)"
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = .black
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

// MARK: - The window

struct OnboardingView: View {
    @Bindable var model: Onboarding
    /// Fits a 13" display under the menu bar; the steps scroll when they need more.
    static let size = CGSize(width: 640, height: 680)

    var body: some View {
        VStack(spacing: 0) {
            StepIndicator(model: model)
                .frame(height: 28)
            ZStack(alignment: .top) {
                page(model.step)
                    .id(model.step)
                    .transition(slide)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Color.black)
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
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
            Page(title: "Meet Tara",
                 line: "\(Brand.displayName) turns the notch into a calm place for your agents, meetings and music. Tara lives there and comes out when something needs you.") {
                TaraStep(model: model)
            }
        case .agents:
            Page(title: "Your agents",
                 line: "What \(Brand.displayName) found on this Mac. One click connects it; every change keeps a backup and can be undone in Settings.") {
                AgentsStep(model: model)
            }
        case .meetings:
            Page(title: "Meetings and Tara's brain",
                 line: "Tara remembers what was said in your meetings and points out contradictions, open questions and promises.") {
                MeetingsStep(model: model)
            }
        case .tools:
            Page(title: "Tools",
                 line: "Switch on what you want in the notch; the rest stays out of the way. Settings › Tools has the same switches.") {
                ToolsStep(model: model)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if model.step != .tara {
                Button("Back") { model.back() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
            }
            Spacer()
            if model.step != .tools {
                Button("Skip") { model.next() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
            }
            primary
        }
        .font(.system(size: 13))
        .padding(.horizontal, 40)
        .padding(.top, 14)
        .padding(.bottom, 24)
    }

    @ViewBuilder private var primary: some View {
        let setup = model.setup
        let running = setup.status.values.contains(.running)
        let pending = setup.selected.filter { !setup.isSetUp($0) && setup.status[$0] == nil && setup.offered.contains($0) }
        if model.step == .agents && running {
            primaryButton("Setting up…") {}.disabled(true)
        } else if model.step == .agents && !pending.isEmpty {
            primaryButton(pending.count == 1 ? "Set up 1 item" : "Set up \(pending.count) items") { setup.setUp(pending) }
        } else if model.step == .tools {
            primaryButton("Start using \(Brand.displayName)") { model.next() }
        } else {
            primaryButton("Continue") { model.next() }
        }
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

/// Four short bars at the top: where you are; a click jumps to any step.
private struct StepIndicator: View {
    let model: Onboarding

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Onboarding.Step.allCases, id: \.self) { step in
                let current = step == model.step
                let done = step.rawValue < model.step.rawValue
                Button { model.go(to: step) } label: {
                    Capsule()
                        .fill(current ? Theme.accent : Color.white.opacity(done ? 0.42 : 0.14))
                        .frame(width: 40, height: 4)
                        .frame(width: 46, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text(LocalizedStringKey(step.name)))
                .accessibilityLabel(Text(LocalizedStringKey(step.name)))
                .accessibilityAddTraits(current ? .isSelected : [])
                .animation(Onboarding.motion, value: model.step)
            }
        }
    }
}

/// A step: its title, one line, and what it asks.
private struct Page<Content: View>: View {
    let title: LocalizedStringKey
    let line: LocalizedStringKey
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(.system(size: 26, weight: .semibold))
                    Text(line)
                        .font(.system(size: 13.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content()
            }
            .padding(.horizontal, 40)
            .padding(.top, 26)
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

/// Rows on one card, with hairlines between them.
private struct CardList<Item: Hashable, Row: View>: View {
    let items: [Item]
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element) { index, item in
                if index > 0 { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.leading, 14) }
                row(item)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct OnboardingLabel: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).padding(.leading, 2)
    }
}

// MARK: - 1 Tara

private struct TaraStep: View {
    let model: Onboarding

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            NotchStage(cast: model.cast)
                .frame(height: 200)
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
                    .offset(y: out || Theme.reduceMotion ? 50 : -96)
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

// MARK: - 2 Agents

private struct AgentsStep: View {
    @Bindable var model: Onboarding

    private static let agentItems: [SetupItem] = [.claudePlugin, .statusLine, .mcpServer, .codexHook, .shellHook,
                                                  .cursorHooks, .copilotHooks, .geminiHooks, .opencodePlugin,
                                                  .cursorApprovals, .copilotApprovals]

    var body: some View {
        let setup = model.setup
        let agents = setup.offered.filter { Self.agentItems.contains($0) }
        let mac = setup.offered.filter { !Self.agentItems.contains($0) }
        VStack(alignment: .leading, spacing: 18) {
            if setup.foundAgents.isEmpty {
                Text("No coding agents yet. \(Brand.displayName) picks up Claude Code and Codex as soon as they're installed.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Up to six tools: the chips wrap onto a second line.
                ChipFlow(spacing: 6) {
                    ForEach(setup.foundAgents) { found in
                        Label(found.name, systemImage: found.symbol)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .background(Theme.card, in: Capsule())
                    }
                }
            }
            if !agents.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    OnboardingLabel("For your agents")
                    CardList(items: agents) { SetupItemRow(center: setup, item: $0, detailed: model.detailed) }
                }
            }
            if !mac.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    OnboardingLabel("On this Mac")
                    CardList(items: mac) { SetupItemRow(center: setup, item: $0, detailed: model.detailed) }
                }
            }
            Button(model.detailed ? "Hide the details" as LocalizedStringKey : "Show exactly what changes") {
                withAnimation(Onboarding.motion) { model.detailed.toggle() }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(Theme.accent)
        }
    }
}

// MARK: - 3 Meetings

private struct MeetingsStep: View {
    @Bindable var model: Onboarding

    private enum Source { case jamie, notes, wispr, granola }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                OnboardingLabel(Runtime.vault != nil ? "Meetings and notes" as LocalizedStringKey : "Meetings")
                // Your notes sit next to Jamie (vault strand).
                CardList(items: Runtime.vault != nil ? [Source.jamie, .notes, .wispr, .granola] : [.jamie, .wispr, .granola]) { source in
                    switch source {
                    case .jamie: JamieRow(jamie: model.jamie)
                    case .notes: NotesRow(state: model.state)
                    case .wispr: ComingSoonRow(name: "Wispr Flow", symbol: "mic")
                    case .granola: ComingSoonRow(name: "Granola", symbol: "note.text")
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                OnboardingLabel("How Tara thinks")
                CardList(items: [TaraBrain.claudeCode, .api, .rules]) { brain in
                    BrainRow(model: model, brain: brain)
                }
                Text(model.state.settings.brain == .auto
                     ? "Not chosen yet: Tara uses what she finds. Settings › Meeting agent has the same choice."
                     : "Settings › Meeting agent has the same choice." as LocalizedStringKey)
                    .font(.system(size: 11.5)).foregroundStyle(.tertiary)
                    .padding(.leading, 2)
            }
        }
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

    var body: some View {
        let phase = jamie.phase
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                RowSymbol(name: "waveform", active: synced(phase))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Jamie").font(.system(size: 13, weight: .medium))
                    status(phase)
                        .font(.system(size: 11.5))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                action(phase)
            }
            if phase.isRunning {
                Text("Keeps going when you close this window.")
                    .font(.system(size: 11.5)).foregroundStyle(.tertiary)
                    .padding(.leading, 40)
                    .transition(.opacity)
            }
            if phase.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Signed in with another Jamie account? Sign out of it on meetjamie.ai in your browser first, then use the other account here.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
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
                    .buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 12))
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
            Text(name).font(.system(size: 13, weight: .medium))
            Spacer(minLength: 12)
            Text("Coming soon").font(.system(size: 11.5)).foregroundStyle(.tertiary)
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

    var body: some View {
        let selected = model.state.settings.brain == brain
        let blocked = brain == .claudeCode && !model.claudeFound
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Haptics.tick()
                withAnimation(Onboarding.motion) { model.state.settings.brain = brain }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(selected ? Theme.accent : Color.secondary)
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(LocalizedStringKey(BrainInfo.title(brain))).font(.system(size: 13, weight: .medium))
                            if brain == .claudeCode && model.claudeFound {
                                Text("Recommended")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(Theme.accent)
                                    .padding(.horizontal, 6)
                                    .frame(height: 17)
                                    .background(Theme.accent.opacity(0.14), in: Capsule())
                            }
                        }
                        Text(LocalizedStringKey(blocked ? "Needs Claude Code on this Mac." : BrainInfo.line(brain)))
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
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
        case .rules: "Simple rules"
        }
    }

    static func line(_ brain: TaraBrain) -> String {
        switch brain {
        case .auto: "Claude Code when it's there, else an API key, else simple rules."
        case .claudeCode: "Runs through Claude Code on your plan; no API credits."
        case .api: "Your Anthropic key, billed per use."
        case .rules: "No model. Works offline and catches the obvious."
        }
    }
}

// MARK: - 4 Tools

private struct ToolsStep: View {
    let model: Onboarding

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
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

/// Lays chips out left to right and wraps them onto the next line when the row is full.
private struct ChipFlow: Layout {
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
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(width: CGFloat, subviews: Subviews) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
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
}
