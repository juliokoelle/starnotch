import AppKit
import NotchCore
import Observation
import SwiftUI

/// The meeting agent (`agent/`) in the notch: Start listens through the microphone, Demo replays
/// a recorded meeting, and every contradiction, question, commitment, answer or prep card the
/// agent finds shows here in full, newest first.
///
/// Two processes, as agent/PROTOCOL.md describes: a source (`transcribe.py`, or the text replay
/// when there's no Reson8 key) and `agent.py`. The app forwards the source's lines into the
/// agent's stdin, so it can also send its own commands (`save`, `prep`, `reset`).
@MainActor
@Observable
final class MeetingModule: NotchModule {
    enum Phase: Equatable {
        case idle
        case running(demo: Bool)
        /// The source ended; the agent still runs and can save.
        case stopped(demo: Bool)
        case saving
    }

    struct Entry: Identifiable, Equatable {
        let id: Int
        let card: MeetingCard
        let time: Date
    }

    let kind = ModuleKind.meeting
    let symbol = ModuleSymbols.symbol(.meeting)

    private(set) var phase = Phase.idle
    private(set) var entries: [Entry] = []
    /// The last thing said, as a quiet caption.
    private(set) var caption: String?
    /// One line about the agent: ready, offline, saved, an error.
    private(set) var message: String?
    private(set) var utterances = 0
    /// `jamie_sync.py` runs: Jamie's meetings come into the memory.
    private(set) var syncing = false
    /// Jamie's login page while the sync waits for it; the browser may have opened it behind other windows.
    private(set) var jamieLogin: URL?
    /// Scrolled to and outlined (a click on a sneak).
    var focused: Int?

    /// A new card: the app shows it as a sneak.
    @ObservationIgnored var onCard: (Entry) -> Void = { _ in }
    /// "Pop out": the character leaves the notch as a floating companion.
    @ObservationIgnored var onPopOut: (() -> Void)?
    /// Listening started or stopped (the companion's mood).
    @ObservationIgnored var onListening: (Bool) -> Void = { _ in }
    /// The next calendar event: its title names the saved meeting, its attendees the prep.
    @ObservationIgnored var nextEvent: () -> (title: String, attendees: [String])? = { nil }

    @ObservationIgnored private var agent: MeetingProcess?
    @ObservationIgnored private var agentIsDemo = false
    /// Counts agents started, so an old one ending after Save or Close is told apart.
    @ObservationIgnored private var agentGeneration = 0
    @ObservationIgnored private var source: MeetingProcess?
    @ObservationIgnored private var jamie: MeetingProcess?
    @ObservationIgnored private var syncedCount = 0
    @ObservationIgnored private var nextID = 0

    private var directory: URL { Runtime.meetingAgentDir }
    private var log: URL { Brand.supportFolder.appending(path: "meeting-agent.log") }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    var agentAlive: Bool { agent != nil }

    // MARK: Actions

    func start(demo: Bool) {
        guard FileManager.default.fileExists(atPath: directory.appending(path: "agent.py").path) else {
            message = "agent.py not found in \(directory.path); set [meeting] agent_dir in config.toml"
            return
        }
        guard MeetingAgentSetup.uvPath != nil else {
            message = "The meeting agent needs uv: Settings › Meeting agent › Install uv"
            return
        }
        if agent != nil, agentIsDemo != demo { endAgent() }
        if let agent {
            agent.write(Data(#"{"cmd":"reset"}"#.utf8 + [0x0A]))
        } else {
            startAgent(demo: demo)
        }
        withAnimation(Theme.snappy) {
            entries = []
            caption = nil
            utterances = 0
            focused = nil
        }
        // Demo: the recorded meeting through Reson8 when there's a key, else the same meeting as text.
        let command = demo
            ? #"if [[ -n "$RESON8_API_KEY" && -f demo/live.wav ]]; then exec uv run python transcribe.py --file demo/live.wav --language de; else exec uv run python demo/play.py --commands; fi"#
            : "exec uv run --extra mic python transcribe.py --mic --language de"
        source = MeetingProcess(command: command, directory: directory, log: log, onLine: { [weak self] line in
            Task { @MainActor in self?.sourceLine(line) }
        }, onExit: { [weak self] in
            Task { @MainActor in self?.sourceEnded() }
        })
        if source == nil { message = "Couldn't start the transcriber" }
        Haptics.confirm()
        set(source == nil ? .stopped(demo: demo) : .running(demo: demo))
    }

    func stop() {
        source?.terminate()
        source = nil
        Haptics.tick()
        if case .running(let demo) = phase { set(.stopped(demo: demo)) }
    }

    /// Stores the meeting in the memory, then lets the agent end.
    func save() {
        guard let agent else { return }
        let title = nextEvent()?.title ?? "Meeting"
        agent.write(MeetingCommand.save(title: title))
        set(.saving)
        message = "Saving “\(title)”…"
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, self.phase == .saving else { return }
            self.message = "The agent didn't confirm the save; see meeting-agent.log"
            self.endAgent()
            self.set(.idle)
        }
    }

    /// Ends without saving.
    func close() {
        stop()
        endAgent()
        set(.idle)
    }

    /// Prep card for the next calendar event's attendees.
    func prepare() {
        guard let event = nextEvent() else { return }
        if agent == nil {
            startAgent(demo: false)
            if phase == .idle { set(.stopped(demo: false)) }
        }
        agent?.write(MeetingCommand.prep(participants: event.attendees))
        Haptics.tick()
    }

    /// Pulls meetings from Jamie over its MCP server into the memory, then has a running agent
    /// re-read it. The first run opens the browser for Jamie's login.
    func syncJamie() {
        guard jamie == nil else { return }
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        syncedCount = 0
        jamie = MeetingProcess(command: "exec uv run python jamie_sync.py", directory: directory, log: log, onLine: { [weak self] line in
            Task { @MainActor in self?.jamieLine(line) }
        }, onExit: { [weak self] in
            Task { @MainActor in self?.jamieEnded() }
        })
        syncing = jamie != nil
        message = jamie == nil ? "Couldn't start the Jamie sync" : "Jamie: connecting…"
        Haptics.tick()
    }

    private func jamieLine(_ line: Data) {
        switch MeetingLine.parse(line) {
        case .status("login", let url):
            jamieLogin = url.flatMap(URL.init(string:))
            message = "Jamie: sign in in your browser (Sign in opens it again)"
        case .synced(let title):
            jamieLogin = nil
            syncedCount += 1
            message = "Jamie: \(syncedCount) · \(title)"
        case .syncDone(let meetings, _):
            message = "Jamie: \(meetings) meeting\(meetings == 1 ? "" : "s") synced into the memory"
            agent?.write(MeetingCommand.reload)
        case .error(let text):
            message = text
        default:
            break
        }
    }

    private func jamieEnded() {
        jamie = nil
        jamieLogin = nil
        syncing = false
    }

    /// The app quits: end everything now.
    func shutdown() {
        jamie?.terminate()
        jamie = nil
        source?.terminate()
        agent?.terminate()
        source = nil
        agent = nil
    }

    // MARK: Processes

    private func startAgent(demo: Bool) {
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        let command = demo
            ? "exec uv run python agent.py --memory demo/meetings --today 2026-10-26"
            : "exec uv run python agent.py --watch-captures"
        agentGeneration += 1
        let generation = agentGeneration
        let process = MeetingProcess(command: command, directory: directory, log: log, onLine: { [weak self] line in
            Task { @MainActor in self?.agentLine(line) }
        }, onExit: { [weak self] in
            Task { @MainActor in self?.agentEnded(generation) }
        })
        agent = process
        agentIsDemo = demo
        message = process == nil ? "Couldn't start the agent" : "Starting the agent…"
    }

    private func endAgent() {
        guard let agent else { return }
        self.agent = nil
        agent.closeInput()
        // A clean end answers what's pending first; after a few seconds, end it anyway.
        Task {
            try? await Task.sleep(for: .seconds(4))
            agent.terminate()
        }
    }

    private func sourceLine(_ line: Data) {
        // Everything the source prints goes to the agent unchanged (it ignores status lines);
        // shell noise that isn't JSON stays out.
        guard line.first == UInt8(ascii: "{") else { return }
        agent?.write(line + [0x0A])
        switch MeetingLine.parse(line) {
        case .utterance(let speaker, let text):
            utterances += 1
            withAnimation(Theme.snappy) { caption = speaker.isEmpty ? text : "\(speaker): \(text)" }
        case .error(let text):
            message = text
        default:
            break
        }
    }

    private func sourceEnded() {
        source = nil
        if case .running(let demo) = phase { set(.stopped(demo: demo)) }
    }

    private func agentLine(_ line: Data) {
        switch MeetingLine.parse(line) {
        case .ready(let meetings, let model):
            message = "\(meetings) meeting\(meetings == 1 ? "" : "s") in memory · " + (model ?? "rules only, no Claude")
        case .card(let card):
            nextID += 1
            let entry = Entry(id: nextID, card: card, time: Date())
            withAnimation(Theme.snappy) { entries.insert(entry, at: 0) }
            onCard(entry)
        case .status(let state, let text):
            if state == "saved" {
                message = "Saved to the memory"
                if phase == .saving {
                    endAgent()
                    set(.idle)
                }
            } else if state == "offline" {
                message = text ?? "Claude isn't reachable; running on rules"
            }
        case .error(let text):
            message = text
        case .utterance, .synced, .syncDone, nil:
            break
        }
    }

    private func agentEnded(_ generation: Int) {
        // Only the current agent matters; an old one ending after Save or Close is expected.
        guard generation == agentGeneration, agent != nil else { return }
        agent = nil
        source?.terminate()
        source = nil
        message = "The agent stopped; see meeting-agent.log in the app's folder"
        set(.idle)
    }

    private func set(_ phase: Phase) {
        withAnimation(Theme.peek) { self.phase = phase }
        onListening(isRunning)
    }

    // MARK: NotchModule

    var count: Int? { entries.isEmpty ? nil : entries.count }
    var ambientPriority: Int { isRunning ? 35 : 0 }
    var needsAttention: Bool { isRunning }
    var bodyHeight: CGFloat { 380 }

    func handleBack() -> Bool {
        guard focused != nil else { return false }
        focused = nil
        return true
    }

    func leadingEar(peek: Bool) -> AnyView {
        AnyView(Circle().fill(isRunning ? Theme.critical : Theme.textTertiary).frame(width: 7, height: 7))
    }

    func trailingEar(peek: Bool) -> AnyView {
        AnyView(Group {
            if let latest = entries.first {
                Image(systemName: MeetingStyle.symbol(latest.card.kind))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(MeetingStyle.tint(latest.card.kind))
            } else {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            }
        })
    }

    func peekLine() -> AnyView {
        let text: String = switch phase {
        case .running: caption ?? "Listening…"
        case .stopped, .saving: entries.isEmpty ? "Meeting ended" : "\(entries.count) cards from this meeting"
        case .idle: "Meeting agent: click to start"
        }
        return AnyView(HStack {
            Text(text).font(Theme.font(13, .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
            Spacer(minLength: 0)
        })
    }

    func body() -> AnyView { AnyView(MeetingBody(module: self)) }

    func primaryAction() {}
}

enum MeetingStyle {
    static func tint(_ kind: MeetingCard.Kind) -> Color {
        switch kind {
        case .contradiction: Theme.critical
        case .question: Theme.waiting
        case .commitment: Theme.ok
        case .answer, .prep: Theme.accent
        }
    }

    static func sneakTint(_ kind: MeetingCard.Kind) -> Sneak.SneakTint {
        switch kind {
        case .contradiction: .critical
        case .question: .waiting
        case .commitment: .ok
        case .answer, .prep: .accent
        }
    }

    static func symbol(_ kind: MeetingCard.Kind) -> String {
        switch kind {
        case .contradiction: "exclamationmark.triangle.fill"
        case .question: "questionmark.bubble.fill"
        case .commitment: "checkmark.seal.fill"
        case .answer: "text.bubble.fill"
        case .prep: "doc.text.fill"
        }
    }
}

private struct MeetingBody: View {
    let module: MeetingModule

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let caption = module.caption, module.isRunning {
                Text(caption)
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .transition(.opacity)
            }
            if module.entries.isEmpty {
                NotchCard {
                    Text(emptyText)
                        .font(Theme.font(13))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                cards
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyText: String {
        switch module.phase {
        case .running: "Listening. Contradictions, questions worth asking and new commitments appear here as they come up."
        case .stopped, .saving: "Nothing came up in this meeting."
        case .idle: "Start listens through the microphone; Demo replays a recorded meeting. The agent compares what's said with earlier meetings and shows contradictions, questions and commitments here, in full."
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.font(14, .semibold)).foregroundStyle(Theme.textPrimary)
                if let message = module.message {
                    Text(message).font(Theme.font(11.5)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let popOut = module.onPopOut {
                HoverRow(cornerRadius: 9, restOpacity: 0.07, hoverOpacity: 0.13,
                         help: "Pop out: the character floats beside your call and shows each card as a bubble") {
                    popOut()
                } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textBody)
                        .frame(width: 28, height: 28)
                }
            }
            switch module.phase {
            case .idle:
                if let event = module.nextEvent(), !event.attendees.isEmpty {
                    MeetingButton(title: "Prepare", symbol: "doc.text", help: "Prep card for \(event.title)") { module.prepare() }
                }
                JamieButton(module: module)
                MeetingButton(title: "Demo", symbol: "play", help: "Replay the recorded demo meeting, no microphone") { module.start(demo: true) }
                MeetingButton(title: "Start", symbol: "mic.fill", prominent: true, help: "Listen through the microphone") { module.start(demo: false) }
            case .running:
                MeetingButton(title: "Stop", symbol: "stop.fill", prominent: true, help: "End listening") { module.stop() }
            case .stopped(let demo):
                if !demo && module.utterances > 0 {
                    MeetingButton(title: "Save", symbol: "tray.and.arrow.down", prominent: true,
                                  help: "Store this meeting in the memory") { module.save() }
                }
                JamieButton(module: module)
                MeetingButton(title: "Close", symbol: "xmark", help: demo ? "End the demo" : "End without saving") { module.close() }
                MeetingButton(title: "Start", symbol: "mic.fill", help: "A new meeting through the microphone") { module.start(demo: false) }
            case .saving:
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 4)
    }

    private var title: String {
        switch module.phase {
        case .idle: "Meeting"
        case .running(let demo): demo ? "Demo meeting" : "Listening"
        case .stopped: "Meeting ended"
        case .saving: "Saving"
        }
    }

    private var cards: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(module.entries) { entry in
                        MeetingCardView(entry: entry, focused: module.focused == entry.id)
                            .id(entry.id)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
            .scrollClipDisabled(false)
            .onChange(of: module.focused) { _, id in
                guard let id else { return }
                withAnimation(Theme.snappy) { proxy.scrollTo(id, anchor: .top) }
            }
            .onAppear {
                if let id = module.focused { proxy.scrollTo(id, anchor: .top) }
            }
        }
    }
}

private struct MeetingCardView: View {
    let entry: MeetingModule.Entry
    let focused: Bool

    var body: some View {
        let tint = MeetingStyle.tint(entry.card.kind)
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: MeetingStyle.symbol(entry.card.kind)).font(.system(size: 11, weight: .bold))
                Text(entry.card.title).font(Theme.font(12.5, .semibold))
                if entry.card.kind == .prep, let detail = entry.card.detail {
                    Text(detail).font(Theme.font(12)).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Text(TimeText.clock(entry.time)).font(Theme.font(11).monospacedDigit()).foregroundStyle(Theme.textTertiary)
            }
            .foregroundStyle(tint)
            ForEach(Array(entry.card.blocks.enumerated()), id: \.offset) { _, block in
                blockView(block, tint: tint)
            }
        }
        .textSelection(.enabled)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(tint.opacity(focused ? 0.7 : 0), lineWidth: 1.5)
        }
    }

    @ViewBuilder
    private func blockView(_ block: MeetingCard.Block, tint: Color) -> some View {
        switch block {
        case .heading(let text):
            Text(text)
                .font(Theme.font(11, .semibold))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        case .text(let text):
            Text(text)
                .font(Theme.font(13))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        case .quote(let text, let source):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(tint.opacity(0.55)).frame(width: 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(text)
                        .font(Theme.font(12.5).italic())
                        .foregroundStyle(Theme.textBody)
                        .fixedSize(horizontal: false, vertical: true)
                    if !source.isEmpty {
                        Text(source).font(Theme.font(11)).foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

/// Sync from Jamie; a spinner while it runs.
private struct JamieButton: View {
    let module: MeetingModule

    var body: some View {
        if let login = module.jamieLogin {
            MeetingButton(title: "Sign in", symbol: "person.badge.key", prominent: true,
                          help: "Open Jamie's login in the browser") { NSWorkspace.shared.open(login) }
        } else if module.syncing {
            ProgressView().controlSize(.small).padding(.horizontal, 8)
        } else {
            MeetingButton(title: "Jamie", symbol: "arrow.triangle.2.circlepath",
                          help: "Bring your meetings from Jamie into the memory") { module.syncJamie() }
        }
    }
}

private struct MeetingButton: View {
    let title: String
    let symbol: String
    var prominent = false
    let help: String
    let action: () -> Void

    var body: some View {
        HoverRow(cornerRadius: 9, tint: prominent ? Theme.accent : .white, restOpacity: prominent ? 0.22 : 0.07,
                 hoverOpacity: prominent ? 0.34 : 0.13, help: help, action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold))
                Text(title).font(Theme.font(12.5, .medium))
            }
            .foregroundStyle(prominent ? Theme.textPrimary : Theme.textBody)
            .padding(.horizontal, 10)
            .frame(height: 28)
        }
    }
}
