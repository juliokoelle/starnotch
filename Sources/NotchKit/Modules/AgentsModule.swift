import AppKit
import QuartzCore
import Darwin
import NotchCore
import Observation
import SwiftUI

/// Live overview of the user's agents: Claude Code sessions on this Mac (with their subagents),
/// loops from a `JobsProvider` connector, and local launchd jobs.
@MainActor
@Observable
final class AgentsModule: NotchModule {
    let kind = ModuleKind.agents
    let symbol = ModuleSymbols.symbol(.agents)

    private(set) var snapshot = AgentSnapshot()
    /// Claude Code sessions of the last days that ended, for "Resume" (read when the panel opens).
    private(set) var recent: [RecentSession] = []
    /// The agent shown big; `nil` follows the most recent working one.
    var selectedID: String?
    var showsLoops = false
    /// Sessions that just finished their turn, shown celebrating for a moment.
    private(set) var finishedAt: [String: Date] = [:]
    let cast: AvatarCast

    /// How long the "finished" moment lasts.
    static let finishedWindow: TimeInterval = 3.2
    /// Called when a session finishes its turn (busy -> idle).
    @ObservationIgnored var onFinished: ((AgentSnapshot.Agent) -> Void)?
    /// The figure pulled down out of the open notch (the companion then follows the pointer by itself).
    @ObservationIgnored var onFigurePull: (() -> Void)?
    /// Loop detail card in the panel (`nil` = list or sessions).
    var selectedLoop: String?
    /// Loops view: list (default) or today's timeline.
    var loopsAsTimeline = false
    /// Music, for the small equalizer next to the agent count.
    @ObservationIgnored weak var music: NowPlayingModule?
    /// Loop state pushed through the local API (`{"loop": "...", "state": "running"}`).
    private(set) var pushes: [String: (state: String, since: Date)] = [:]
    /// What Claude Code's status line reported per session (via scripts/statusline-bridge.sh):
    /// exact context window and the official 5-hour and weekly limits. Empty until set up.
    private(set) var statuses: [String: StatusSnapshot] = [:]
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    /// Recordings: a fixed plan snapshot.
    var previewPlan: StatusSnapshot?
    /// Plan limits from other tools (Codex), refreshed with the scan.
    private(set) var toolUsages: [AgentUsage] = []
    /// Recordings: fixed limits of other tools.
    var previewUsages: [AgentUsage]?
    @ObservationIgnored private var usagesAt = Date.distantPast
    /// Used % over time per tool window ("codex.5 h"), for the pace forecast; the last hour.
    @ObservationIgnored private var usageSamples: [String: [(at: Date, used: Double)]] = [:]
    /// A plan window crossed 80 % or 90 %: tool, window, used %, the forecast sentence.
    @ObservationIgnored var onLimitAlert: ((String, String, Double, String?) -> Void)?
    /// A loop finished (a new logged run or a push): for its sneak.
    @ObservationIgnored var onLoopFinished: ((AgentSnapshot.LoopStatus) -> Void)?
    /// The agents inbox, for its count in the ear (set by the app).
    @ObservationIgnored weak var inbox: AgentsInbox?
    var inboxCount: Int { inbox?.count ?? 0 }
    @ObservationIgnored private var previewMode = false
    /// Pending approvals already turned into a step of their session.
    @ObservationIgnored private var ingestedApprovals: Set<String> = []

    /// Idle sessions count as "waiting for you" this long after their last turn.
    static let waitingWindow: TimeInterval = 10 * 60
    static let loopColor = Color(hex: 0xC9CED8)

    @ObservationIgnored private let scanner = AgentScanner()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var isExpanded = false
    @ObservationIgnored private var didLoadOnce = false
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var refreshQueued = false
    @ObservationIgnored private var lastWatchScan = Date.distantPast
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var refreshAgain = false

    init(cast: AvatarCast) {
        self.cast = cast
    }

    /// Design preview: fixed data instead of the real scan.
    func usePreview(_ snapshot: AgentSnapshot) {
        previewMode = true
        pollTask?.cancel()
        watcher = nil
        self.snapshot = snapshot

    }

    /// Design preview: the running loop completes.
    func finishLoop(_ name: String) {
        guard let index = snapshot.loops.firstIndex(where: { $0.name == name }) else { return }
        var loop = snapshot.loops[index]
        loop.isRunning = false
        loop.progress = nil
        let entry = LoopRun(day: AgentScanner.day(Date()), loop: name, status: .ok, note: "done")
        loop.last = entry
        loop.history.append(entry)
        if let slot = loop.slots.firstIndex(where: { $0.status == nil && !$0.missed && $0.at <= Date().addingTimeInterval(120) }) {
            loop.slots[slot].status = .ok
        }
        withAnimation(Theme.open) { snapshot.loops[index] = loop }
        onLoopFinished?(loop)
    }

    // MARK: Loops

    enum LoopPhase: Equatable {
        case running, waiting, failed, done

        var color: Color {
            switch self {
            case .running: Theme.ok
            case .waiting: Theme.waiting
            case .failed: Theme.critical
            case .done: Color.white.opacity(0.22)
            }
        }

        var word: String {
            switch self {
            case .running: "running"
            case .waiting: "needs a look"
            case .failed: "failed"
            case .done: "done"
            }
        }

        var faceMood: AgentFace.Mood {
            switch self {
            case .running: .working
            case .waiting: .waiting
            case .failed: .failed
            case .done: .idle
            }
        }
    }

    /// The snapshot's loop with pushed state applied.
    func merged(_ loop: AgentSnapshot.LoopStatus) -> AgentSnapshot.LoopStatus {
        guard let push = pushes[loop.name] else { return loop }
        var loop = loop
        loop.isRunning = push.state == "running"
        loop.runningSince = loop.isRunning ? push.since : nil
        loop.isWaiting = push.state == "waiting"
        if push.state == "fail" { loop.last = LoopRun(day: AgentScanner.day(push.since), loop: loop.name, status: .fail, note: "reported failed") }
        return loop
    }

    var loops: [AgentSnapshot.LoopStatus] { snapshot.loops.map(merged) }

    func phase(of loop: AgentSnapshot.LoopStatus) -> LoopPhase {
        if loop.isRunning { return .running }
        if loop.isWaiting { return .waiting }
        switch loop.last?.status {
        case .fail: return .failed
        case .degraded: return .waiting
        default: return loop.isLate ? .waiting : .done
        }
    }

    /// From the local API.
    func applyPush(loop name: String, state: String) {
        let finished = state == "ok" || state == "fail"
        withAnimation(Theme.snappy) { pushes[name] = finished ? nil : (state, Date()) }
        if finished, var loop = snapshot.loops.first(where: { $0.name == name }) {
            if state == "fail" { loop.last = LoopRun(day: AgentScanner.day(Date()), loop: name, status: .fail, note: "reported failed") }
            onLoopFinished?(loop)
        }
    }

    /// The list of all loops (never a single loop's detail).
    func openLoopsOverview() {
        Haptics.tick()
        withAnimation(Theme.snappy) {
            showsLoops = true
            selectedLoop = nil
        }
    }

    func openLoop(_ name: String) {
        Haptics.tick()
        withAnimation(Theme.snappy) {
            showsLoops = true
            selectedLoop = name
        }
    }

    /// ← or Esc inside the agents panel: detail → list → sessions.
    func handleBack() -> Bool {
        if subagentID != nil {
            withAnimation(Theme.snappy) { subagentID = nil }
            return true
        }
        if detailID != nil {
            withAnimation(Theme.snappy) { detailID = nil }
            return true
        }
        if selectedLoop != nil {
            withAnimation(Theme.snappy) { selectedLoop = nil }
            return true
        }
        if showsLoops {
            withAnimation(Theme.snappy) { showsLoops = false }
            return true
        }
        return false
    }

    /// Reads the status line bridge's files every 10 s (a handful of small files).
    func startStatus() {
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                let next = await Task.detached(priority: .utility) { StatusFiles.read() }.value
                guard let self else { return }
                if next != self.statuses { withAnimation(Theme.snappy) { self.statuses = next } }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    /// The plan limits: the newest snapshot that has them (they're the same for every session).
    var plan: StatusSnapshot? {
        if let previewPlan { return previewPlan }
        return statuses.values.filter { $0.fiveHour != nil || $0.sevenDay != nil }.max { $0.capturedAt < $1.capturedAt }
    }

    /// Every tool's plan limits, the one closest to its limit first. Claude's come from its
    /// status line bridge, Codex's from its session files.
    var usages: [AgentUsage] {
        var all = previewUsages ?? toolUsages
        if let plan, plan.fiveHour != nil || plan.sevenDay != nil {
            all.append(AgentUsage(provider: ClaudeCodeProvider.id, displayName: "Claude",
                                  primary: plan.fiveHour.map { .init(usedPercent: $0.usedPercentage, minutes: 300, resetsAt: $0.resetsAt) },
                                  secondary: plan.sevenDay.map { .init(usedPercent: $0.usedPercentage, minutes: 10_080, resetsAt: $0.resetsAt) },
                                  capturedAt: plan.capturedAt))
        }
        return AgentUsage.ordered(all)
    }

    /// Samples each window's used % and announces crossing 80 % and 90 % with the forecast.
    private func recordUsage(now: Date) {
        for usage in usages.map({ $0.current(now: now) }) {
            for window in [usage.primary, usage.secondary].compactMap({ $0 }) {
                let key = "\(usage.provider).\(window.label)"
                var samples = usageSamples[key] ?? []
                let previous = samples.last?.used
                if let last = samples.last, window.usedPercent < last.used - 5 { samples.removeAll() }  // the window reset
                samples.append((now, window.usedPercent))
                samples.removeAll { now.timeIntervalSince($0.at) > 3600 }
                usageSamples[key] = samples
                if let threshold = PaceForecast.crossed(previous: previous, current: window.usedPercent) {
                    _ = threshold
                    // Short for the sneak; the full sentence is in the header's tooltip.
                    let outcome = PaceForecast.projection(usedPercent: window.usedPercent, minutes: window.minutes,
                                                          resetsAt: window.resetsAt, samples: samples, now: now)
                    let short: String? = switch outcome {
                    case .hitsLimit(let at): "full at \(TimeText.clock(at, from: now))"
                    case .lasts: "lasts"
                    case .unknown: nil
                    }
                    onLimitAlert?(usage.displayName, window.label, window.usedPercent, short)
                }
            }
        }
    }

    /// When the window runs out at the current pace: the recent rate once there are samples,
    /// before that the window's average since it opened.
    func pace(_ provider: String, _ window: AgentUsage.Window, now: Date = Date()) -> PaceForecast.Outcome {
        let samples = usageSamples["\(provider).\(window.label)"] ?? []
        return PaceForecast.projection(usedPercent: window.usedPercent, minutes: window.minutes, resetsAt: window.resetsAt,
                                       samples: samples, now: now)
    }

    /// "At this pace your 5-hour limit is full at 16:40" / "Lasts until the reset at 18:00".
    func forecast(_ provider: String, _ window: AgentUsage.Window, now: Date = Date()) -> String? {
        switch pace(provider, window, now: now) {
        case .hitsLimit(let at):
            let name = window.label == "week" ? Localization.string("weekly") : window.label == "5 h" ? Localization.string("5-hour") : window.label
            return String(format: Localization.string("At this pace your %@ limit is full at %@"), name, TimeText.clock(at, from: now))
        case .lasts(let until):
            return until.map { String(format: Localization.string("Lasts until the reset at %@"), TimeText.clock($0, from: now)) }
                ?? Localization.string("Lasts until the reset")
        case .unknown:
            return nil
        }
    }

    /// The earliest "full 16:40" among a tool's windows.
    func paceShort(of usage: AgentUsage, now: Date = Date()) -> String? {
        let hits = [usage.primary, usage.secondary].compactMap { $0 }.compactMap { window -> Date? in
            guard case .hitsLimit(let at) = pace(usage.provider, window, now: now), at > now.addingTimeInterval(60) else { return nil }
            return at
        }
        return hits.min().map { String(format: Localization.string("full %@"), TimeText.clock($0, from: now)) }
    }

    /// "full 16:40" for a header pill: only when the window runs out before its reset.
    func paceShort(_ provider: String, _ window: AgentUsage.Window, now: Date = Date()) -> String? {
        guard case .hitsLimit(let at) = pace(provider, window, now: now), at > now.addingTimeInterval(60) else { return nil }
        return String(format: Localization.string("full %@"), TimeText.clock(at, from: now))
    }

    /// More than one tool has sessions: chips carry a small tool badge.
    var showsToolBadges: Bool { Set(snapshot.agents.map(\.provider)).count > 1 }

    /// The tool's short name on its pill: "Claude", "Codex".
    static func toolLabel(of provider: String) -> String {
        switch provider {
        case CodexProvider.id: "Codex"
        case ClaudeCodeProvider.id: "Claude"
        case CopilotProvider.id: "Copilot"
        case GeminiProvider.id: "Gemini"
        default: toolName(of: provider)
        }
    }

    /// One tint per tool, the same on every pill (no company logos: they aren't ours to ship).
    static func toolTint(of provider: String) -> Color {
        switch provider {
        case CodexProvider.id: Color(hex: 0x4FC3B5)
        case ClaudeCodeProvider.id: Color(hex: 0xE0875F)
        // The other tools: a neutral badge; their name tells them apart.
        default: Theme.textSecondary
        }
    }

    static func toolName(of provider: String) -> String {
        AgentScanner.providerTypes.first { $0.id == provider }?.displayName ?? provider
    }

    /// Providers switched off in Settings.
    func setDisabledProviders(_ ids: Set<String>) {
        Task { [weak self] in
            guard let self else { return }
            await self.scanner.setDisabled(ids)
            await self.refresh()
        }
    }

    /// Pending approvals: their sessions wait for the user (a hook beats the files).
    func setPendingApprovals(_ requests: [ApprovalRequest]) {
        let events = requests.compactMap { request in
            request.agentID.map { AgentEvent(sessionID: $0, kind: .needsApproval(AgentEvent.approvalPrefix + (request.summary.isEmpty ? request.tool : request.summary)), at: Date()) }
        }
        // A prompt from a hooked tool (Cursor, Copilot CLI, opencode) may be the first its session
        // says: it makes the session known, with its process for the jump. Each request once.
        let fresh = requests.filter { !ingestedApprovals.contains($0.id) }
        ingestedApprovals = Set(requests.map(\.id))
        let updates = fresh.compactMap { request -> HookUpdate? in
            guard let session = request.sessionID, request.provider != ClaudeCodeProvider.id, request.provider != CodexProvider.id,
                  request.provider != ApprovalRequest.mcpProvider else { return nil }
            let step = SessionStep(kind: request.tool == "Bash" ? .shell : .tool, text: request.summary.isEmpty ? request.tool : request.summary)
            return HookUpdate(provider: request.provider, sessionID: session, kind: .tool(step), at: Date(),
                              cwd: request.cwd, pid: request.pid, tty: request.tty)
        }
        Task { [weak self] in
            guard let self else { return }
            for update in updates { await self.scanner.ingest(update) }
            await self.scanner.setEvents(events)
            await self.refresh()
        }
    }

    /// A status hook of Cursor, Copilot CLI, Gemini CLI or opencode, as the socket received it.
    func ingestHook(_ data: Data) {
        guard !previewMode else { return }
        Task { [weak self] in
            guard let self, await self.scanner.ingest(data) else { return }
            await self.refresh()
        }
    }

    /// Whether the bridge has ever written anything.
    var statusBridgeInstalled: Bool { previewPlan != nil || !statuses.isEmpty }

    /// Context fullness of a session: exact from the status line, else `nil`.
    func contextPercentage(of agent: AgentSnapshot.Agent) -> Double? {
        if let pct = agent.contextPercentage ?? statuses[agent.id]?.contextUsedPercentage { return pct }
        // Tools that report their window (Codex): exact from the files.
        guard let tokens = agent.contextTokens, let window = agent.contextWindow, window > 0 else { return nil }
        return min(100, Double(tokens) / Double(window) * 100)
    }

    /// "ctx 43 %" or, without the status line, "ctx 143k" (window size unknown).
    func contextLabel(of agent: AgentSnapshot.Agent) -> String? {
        if let pct = contextPercentage(of: agent) { return "ctx \(Int(pct.rounded())) %" }
        if let tokens = agent.contextTokens { return "ctx \(QuotaEstimator.tokens(tokens))" }
        return nil
    }

    func start() {
        guard !previewMode else { return }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        // The same project set as Settings › Projects, so characters match everywhere.
        Task { [weak self] in
            let known = await Task.detached(priority: .utility) { AgentScanner.knownProjects() }.value
            self?.cast.register(known)
        }
        // Busy/idle flips land in ~/.claude/sessions; react to them right away.
        watcher = DirectoryWatcher(path: AgentScanner.claudeDir.appending(path: "sessions").path) { [weak self] in
            Task { @MainActor in self?.refreshSoon() }
        }
    }

    /// Coalesces bursts of file events into one scan, at most one per second.
    private func refreshSoon() {
        guard !refreshQueued, Date().timeIntervalSince(lastWatchScan) > 1 else { return }
        lastWatchScan = Date()
        Log.app.debug("Session files changed, scanning")
        refreshQueued = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self else { return }
            self.refreshQueued = false
            await self.refresh()
        }
    }

    func refresh() async {
        guard !previewMode else { return }
        if isRefreshing {
            refreshAgain = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            refreshAgain = false
            await scanOnce()
        } while refreshAgain
    }

    private func scanOnce() async {
        let next = await scanner.scan(includeJobs: isExpanded)
        if Date().timeIntervalSince(usagesAt) > 30 {
            usagesAt = Date()
            let usages = await scanner.usages()
            if usages != toolUsages, !previewMode { toolUsages = usages }
            recordUsage(now: usagesAt)
        }
        // A preview took over while this scan ran: its made-up sessions stay.
        guard !previewMode, next != snapshot else { return }
        if didLoadOnce {
            let wasBusy = Set(snapshot.agents.filter(\.isBusy).map(\.id))
            for agent in next.agents where wasBusy.contains(agent.id) && !agent.isBusy {
                markFinished(agent.id)
                onFinished?(agent)
            }
            // A subagent that was running is done now: one sneak.
            for agent in next.agents {
                guard let before = snapshot.agents.first(where: { $0.id == agent.id }) else { continue }
                for sub in agent.subagents where sub.status == .done || sub.status == .failed {
                    if before.subagents.first(where: { $0.id == sub.id })?.status == .running {
                        onSubagentFinished?(agent, sub)
                    }
                }
            }
            // A loop logged a new run: it finished.
            for loop in next.loops {
                let before = snapshot.loops.first { $0.name == loop.name }
                if let entry = loop.history.last, before?.history.last != entry || (before?.history.count ?? 0) < loop.history.count,
                   entry.day == AgentScanner.day(Date()) {
                    pushes[loop.name] = nil
                    onLoopFinished?(merged(loop))
                }
            }
        }
        didLoadOnce = true
        cast.register(next.agents.map(\.project))
        withAnimation(Theme.snappy) { snapshot = next }
    }

    /// The finished moment: the session comes forward celebrating, then settles.
    func markFinished(_ id: String) {
        withAnimation(Theme.snappy) { finishedAt[id] = Date() }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.finishedWindow))
            guard let self else { return }
            withAnimation(Theme.snappy) { self.finishedAt[id] = nil }
        }
    }

    func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
        if expanded {
            Task { await refresh() }
            loadRecent()
        } else {
            showsLoops = false
            selectedLoop = nil
            detailID = nil
        }
    }

    // MARK: Recent sessions

    func loadRecent() {
        let live = Set(snapshot.agents.map(\.id))
        Task { [weak self] in
            let found = await Task.detached(priority: .utility) {
                RecentSessions.scan(root: ClaudeCodeProvider.defaultRoot, excluding: live, now: Date())
            }.value
            self?.recent = found
        }
    }

    /// Opens Terminal in the session's folder with `claude --resume <id>` (a .command file, so no
    /// Automation permission is needed).
    func resume(_ session: RecentSession) {
        guard let script = RecentSessions.resumeScript(session) else { return }
        let folder = Brand.supportFolder.appending(path: "resume")
        let file = folder.appending(path: "\(session.id).command")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            Haptics.confirm()
            NSWorkspace.shared.open(file)
        } catch {
            Log.app.error("Resume: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Derived state

    var main: AgentSnapshot.Agent? {
        let finished = finishedAt.max { $0.value < $1.value }?.key
        return snapshot.agents.first { $0.id == selectedID }
            ?? snapshot.agents.first { $0.id == finished }
            ?? snapshot.agents.first
    }

    var others: [AgentSnapshot.Agent] {
        snapshot.agents.filter { $0.id != main?.id }
    }

    var busyCount: Int { snapshot.agents.filter(\.isBusy).count }

    var failedLoops: [AgentSnapshot.LoopStatus] {
        let today = AgentScanner.day(Date())
        return snapshot.loops.filter { $0.last?.status == .fail && $0.last?.day == today }
    }

    func mood(of agent: AgentSnapshot.Agent, now: Date = Date()) -> AgentFace.Mood {
        if agent.needsYou != nil { return .waiting }
        if agent.isBusy { return .working }
        if let since = agent.since, now.timeIntervalSince(since) < Self.waitingWindow { return .waiting }
        return .idle
    }

    func mood(of loop: AgentSnapshot.LoopStatus) -> AgentFace.Mood {
        switch loop.last?.status {
        case .fail: .failed
        case .degraded: .waiting
        case .ok: loop.isLate ? .waiting : .working
        default: loop.isLate ? .waiting : .idle
        }
    }

    /// Avatar mood: what the sprite shows.
    func avatarMood(of agent: AgentSnapshot.Agent, now: Date = Date()) -> AvatarMood {
        if let at = finishedAt[agent.id], now.timeIntervalSince(at) < Self.finishedWindow { return .finished }
        if agent.isBusy {
            switch agent.steps.last?.kind {
            case .edit?, nil: return .working
            case .message?: return .typing
            default: return .thinking
            }
        }
        if mood(of: agent, now: now) == .waiting { return .yourTurn }
        // Idle for 45 minutes or more: asleep.
        if let since = agent.since, now.timeIntervalSince(since) > 45 * 60 { return .asleep }
        return .idle
    }

    /// One character per project; sessions of a project differ by colour (branch, then session).
    func character(of agent: AgentSnapshot.Agent) -> String { cast.character(forProject: agent.project) }

    /// Colorway per session: by performance level (default) or by session; sessions of one
    /// project that land on the same colorway get a small hue offset.
    var sessionColours: [String: (colorway: String, offset: Double)] {
        var result: [String: (String, Double)] = [:]
        for (_, sessions) in Dictionary(grouping: snapshot.agents, by: \.project) {
            let keys = sessions.map { SessionColours.Session(id: $0.id, level: $0.level, started: $0.started) }
            result.merge(SessionColours.assign(keys, by: cast.colourBy, scale: cast.colourScale,
                                               sessionPalette: Colorway.builtIn.map(\.key).filter { $0 != "matte_black" })) { a, _ in a }
        }
        return result
    }

    func colorway(of agent: AgentSnapshot.Agent) -> Colorway {
        // Not tintable (the cat): its own colours, always; sessions differ by title.
        guard cast.isTintable(character(of: agent)) else { return Colorway() }
        guard let entry = sessionColours[agent.id] else { return Colorway() }
        // The character's own look for this level (Astra's colours, the cat's eyes) unless the user
        // set a colour for the level.
        if let level = variantLevel(of: agent), let variant = cast.variant(of: character(of: agent), level: level) {
            return (variant.colorway.map(Colorway.named) ?? Colorway()).shifted(by: entry.offset)
        }
        return Colorway.named(entry.colorway).shifted(by: entry.offset)
    }

    /// The level whose character variant a session shows: colours follow performance, the level
    /// is known, the user hasn't set a colour for it, and the character has a look for it.
    func variantLevel(of agent: AgentSnapshot.Agent) -> PerformanceLevel? {
        cast.look(of: character(of: agent), level: agent.level).level
    }

    func hue(of agent: AgentSnapshot.Agent) -> Double { colorway(of: agent).hue }

    func color(of agent: AgentSnapshot.Agent) -> Color {
        let way = colorway(of: agent)
        guard cast.isTintable(character(of: agent)) else { return cast.library.tint(character(of: agent)) }
        // The character's own look for the level brings its accent (Astra's Sol is orange).
        if let level = variantLevel(of: agent), let hex = cast.variant(of: character(of: agent), level: level)?.tint,
           let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) {
            return Color(hex: value)
        }
        if let tint = way.tint, way.tintAmount > 0.4 { return Color(hex: tint) }
        let base = cast.library.tint(character(of: agent)).hueShifted(way.hue)
        if way.saturation < 0.2 { return way.brightness < 0 ? Color(white: 0.55) : Color(white: 0.85) }
        return base
    }

    /// "max" for the chip; with model in the tooltip.
    func levelLabel(_ agent: AgentSnapshot.Agent) -> String? { agent.level?.rawValue }

    /// Session detail card in the panel.
    var detailID: String?
    /// A subagent's detail card (its id); `detailID` holds its parent.
    var subagentID: String?

    func openDetail(_ agent: AgentSnapshot.Agent) {
        Haptics.tick()
        withAnimation(Theme.snappy) {
            detailID = agent.id
            subagentID = nil
        }
    }

    func openSubagent(_ id: String, of parent: AgentSnapshot.Agent) {
        Haptics.tick()
        withAnimation(Theme.snappy) {
            detailID = parent.id
            subagentID = id
        }
    }

    /// A subagent finished: for its sneak ("<description> done").
    @ObservationIgnored var onSubagentFinished: ((AgentSnapshot.Agent, AgentSnapshot.Subagent) -> Void)?

    /// "notch-switcher · r4-design · idle 6h 33m"; the quiet line under a session's title.
    func secondary(for agent: AgentSnapshot.Agent, now: Date = Date()) -> String {
        var parts = [agent.project]
        if let branch = agent.branch, !["main", "master"].contains(branch) { parts.append(branch) }
        parts.append(status(of: agent, now: now))
        if let level = agent.level { parts.append(level.rawValue) }
        return parts.joined(separator: " · ")
    }

    func status(of agent: AgentSnapshot.Agent, now: Date = Date()) -> String {
        let rest = agent.since.map { Durations.short(now.timeIntervalSince($0)) }
        if agent.isBusy { return "working" + (rest.map { " \($0)" } ?? "") }
        if mood(of: agent, now: now) == .waiting { return "your turn" + (rest.map { " · \($0)" } ?? "") }
        return "idle" + (rest.map { " \($0)" } ?? "")
    }

    /// The session itself: Remote Control sessions on claude.ai, terminal sessions in their own
    /// tab or pane, otherwise the tool's app (Claude, Codex) or the project folder.
    func jump(to agent: AgentSnapshot.Agent) {
        if let url = agent.remoteURL {
            NSWorkspace.shared.open(url)
        } else if SessionJump.open(agent) {
            return
        } else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.appBundleID(of: agent.provider)) {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: agent.cwd))
        }
    }

    /// The desktop app of a tool, for sessions without a terminal.
    static func appBundleID(of provider: String) -> String {
        provider == CodexProvider.id ? "com.openai.codex" : "com.anthropic.claudefordesktop"
    }

    /// One line about an agent that isn't empty: its current step, or how long it has rested.
    func line(for agent: AgentSnapshot.Agent, now: Date = Date()) -> String {
        if let reason = agent.needsYou { return reason }
        if agent.isBusy, let step = agent.steps.last { return step.text }
        let rest = agent.since.map { Durations.short(now.timeIntervalSince($0)) }
        if mood(of: agent, now: now) == .waiting {
            return rest.map { "Your turn · \($0)" } ?? "Your turn"
        }
        if let rest { return "Idle for \(rest)" }
        return agent.steps.last?.text ?? "Idle"
    }

    // MARK: NotchModule

    var count: Int? { busyCount > 0 ? busyCount : nil }

    var ambientPriority: Int {
        let now = Date()
        if !finishedAt.isEmpty || inboxCount > 0 || snapshot.agents.contains(where: { mood(of: $0, now: now) != .idle }) { return 20 }
        return failedLoops.isEmpty ? 0 : 10
    }

    func leadingEar(peek: Bool) -> AnyView {
        AnyView(AgentsLeadingEar(module: self, peek: peek))
    }

    func trailingEar(peek: Bool) -> AnyView {
        AnyView(AgentsTrailingEar(module: self, peek: peek))
    }

    func peekLine() -> AnyView { AnyView(AgentsPeekLine(module: self)) }

    func body() -> AnyView { AnyView(AgentsBody(module: self)) }

    func primaryAction() {
        if let main { focus(main) }
    }

    // MARK: Actions

    /// Brings the terminal (or editor) that runs the session to the front; falls back to the
    /// project folder in Finder. With ⌘ held, always the folder.
    func focus(_ agent: AgentSnapshot.Agent) {
        if !NSEvent.modifierFlags.contains(.command), SessionJump.open(agent) { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: agent.cwd))
    }

    /// Walks up the parent processes until one is a regular app (Terminal, Ghostty, VS Code…).
    static func hostApp(of pid: Int32) -> NSRunningApplication? {
        var current = pid
        for _ in 0..<12 {
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular {
                return app
            }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(current, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
            let parent = Int32(info.pbi_ppid)
            guard parent > 1, parent != current else { return nil }
            current = parent
        }
        return nil
    }

    var holdsOpen: Bool { detailID != nil || subagentID != nil || selectedLoop != nil }

    /// A session waits for the user, or a loop failed today. Working alone doesn't count.
    var needsAttention: Bool {
        let now = Date()
        return snapshot.agents.contains { mood(of: $0, now: now) == .waiting } || !failedLoops.isEmpty || inboxCount > 0
    }

    func openLoopsFolder() {
        if let url = Runtime.jobs?.logURL { NSWorkspace.shared.open(url) }
    }
}

// MARK: - Ears and peek

private struct AgentsLeadingEar: View {
    let module: AgentsModule
    let peek: Bool
    @Environment(\.notch) private var notch

    var body: some View {
        // In the peek the figure moves down into the peek line (same id), bigger.
        if peek {
            Color.clear
        } else {
            MainFigure(module: module, height: 24, sink: 0.25)
                .frame(height: 32, alignment: .bottom)
                .notchMatched("agents.main", in: notch.namespace)
        }
    }
}

/// The main agent's figure, or the resting lead character when nothing runs.
private struct MainFigure: View {
    let module: AgentsModule
    var height: CGFloat
    var sink: CGFloat = 0
    var emergeOnAppear = true
    @State private var draggingOut = false
    @Environment(\.musicPlaying) private var musicPlaying

    var body: some View {
        figure
            .handleSquash()
            .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .global)
                .onChanged { value in
                    // Pulled down past the notch: the figure leaves it and follows the pointer.
                    guard !draggingOut, value.translation.height > 24 else { return }
                    draggingOut = true
                    module.onFigurePull?()
                }
                .onEnded { _ in draggingOut = false })
    }

    @ViewBuilder private var figure: some View {
        if let main = module.main {
            let character = module.character(of: main)
            AvatarView(character: character, mood: module.avatarMood(of: main), height: height,
                       colorway: module.colorway(of: main), sink: sink, emergeOnAppear: emergeOnAppear,
                       level: module.variantLevel(of: main), headphones: musicPlaying)
        } else {
            AvatarView(character: module.cast.main, mood: module.failedLoops.isEmpty ? .idle : .failed,
                       height: height, colorway: module.cast.colorway, sink: sink, emergeOnAppear: emergeOnAppear,
                       headphones: musicPlaying)
        }
    }
}

private struct AgentsTrailingEar: View {
    let module: AgentsModule
    let peek: Bool
    @Environment(\.figuresHidden) private var figuresHidden

    var body: some View {
        HStack(spacing: peek ? 6 : 3) {
            // Music keeps playing in the background: a small equalizer next to the agents.
            // In the narrow compact ear only when no other sessions need the room.
            if let music = module.music, music.isPlaying, let track = music.track, peek || module.others.isEmpty {
                Equalizer(color: track.color, playing: true, height: peek ? 11 : 9)
                    .transition(.blurSlide(scale: 0.6))
            }
            // What waits in the inbox (⌃⌥A) takes the narrow ear; the peek shows it beside the figures.
            let waiting = module.inboxCount
            if waiting > 0 {
                InboxCountBadge(count: waiting, large: peek)
                    .transition(.blurSlide(scale: 0.6))
            }
            if waiting == 0 || peek { content }
        }
    }

    @ViewBuilder private var content: some View {
        // Compact: one figure (the most urgent other session) and a count; the peek has room for three.
        let others = Array(module.others.prefix(peek ? 3 : 1))
        if others.isEmpty {
            if let main = module.main, let since = main.since {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Durations.short(context.date.timeIntervalSince(since)))
                        .font(Theme.font(peek ? 13 : 11, .medium).monospacedDigit())
                        .foregroundStyle(main.isBusy ? Theme.textBody : Theme.textSecondary)
                        .contentTransition(.numericText())
                        .minimumScaleFactor(0.7)
                }
            }
        } else if figuresHidden {
            // Watch mode: the other sessions as a number instead of figures.
            Text("+\(module.others.count)")
                .font(Theme.font(peek ? 13 : 11, .medium).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .help(others.map(\.project).joined(separator: ", "))
        } else {
            // The other agents as small figures peeking from the bottom edge, overlapping.
            HStack(spacing: -7) {
                ForEach(Array(others.enumerated()), id: \.element.id) { index, agent in
                    AvatarView(character: module.character(of: agent), mood: module.avatarMood(of: agent),
                               height: peek ? 24 : 20, colorway: module.colorway(of: agent), sink: peek ? 0 : 0.25,
                               level: module.variantLevel(of: agent))
                        .environment(\.figureOrder, 1 + index)
                }
            }
            .overlay(alignment: .topTrailing) {
                if !peek && module.others.count > 1 {
                    Text("\(module.others.count)")
                        .font(Theme.font(9.5, .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .background(Color.white.opacity(0.22), in: Capsule())
                        .offset(x: 2, y: 2)
                }
            }
            .frame(height: 32, alignment: .bottom)
            .clipped()
            .help(others.map(\.project).joined(separator: ", "))
        }
    }
}

/// How many things wait in the agents inbox: a small count in the waiting tint.
private struct InboxCountBadge: View {
    let count: Int
    var large = false

    var body: some View {
        Text("\(count)")
            .font(Theme.font(large ? 11.5 : 10.5, .bold).monospacedDigit())
            .foregroundStyle(Color.black.opacity(0.85))
            .padding(.horizontal, large ? 5 : 4)
            .frame(minWidth: large ? 18 : 16, minHeight: large ? 18 : 16)
            .background(Theme.waiting, in: Capsule())
            .contentTransition(.numericText())
            .help(Localization.string("Waiting in the inbox (⌃⌥A)"))
            .accessibilityLabel(String(format: Localization.string("%d need you"), count))
    }
}

private struct AgentsPeekLine: View {
    let module: AgentsModule
    @Environment(\.notch) private var notch
    @Environment(\.figuresHidden) private var figuresHidden

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            // Bigger figure, leaning on the island's bottom edge; it grows out of the left ear.
            // Fully below the hardware notch (whatever reaches above it hides behind the camera
            // housing): the top of the head sits 2 pt under the notch's edge. Watch mode: text only.
            if !figuresHidden {
                MainFigure(module: module, height: 37, emergeOnAppear: false)
                    .frame(width: 44, height: 39, alignment: .bottom)
                    .notchMatched("agents.main", in: notch.namespace)
            }
            VStack(alignment: .leading, spacing: 1) {
                if let main = module.main {
                    let title = Text(main.displayTitle)
                        .font(Theme.font(13, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    // The count goes first when the peek is narrow; the title truncates.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) {
                            title.fixedSize()
                            Spacer(minLength: 6)
                            if module.snapshot.agents.count > 1 {
                                Text("\(module.busyCount) of \(module.snapshot.agents.count) working")
                                    .font(Theme.font(12).monospacedDigit())
                                    .foregroundStyle(Theme.textSecondary)
                                    .fixedSize()
                            }
                        }
                        title
                    }
                    Text(module.avatarMood(of: main) == .finished ? "Done" : module.line(for: main))
                        .font(Theme.font(12.5))
                        .foregroundStyle(module.avatarMood(of: main) == .finished ? Theme.ok : Theme.textBody)
                } else {
                    Text("No agents running")
                        .font(Theme.font(13, .medium))
                        .foregroundStyle(Theme.textBody)
                    if let next = module.snapshot.loops.first(where: { $0.nextRun != nil }), let date = next.nextRun {
                        Text("next \(next.name) \(TimeText.clock(date))")
                            .font(Theme.font(12).monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .padding(.bottom, 7)
        }
        .lineLimit(1)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }
}

// MARK: - Expanded body

private struct AgentsBody: View {
    let module: AgentsModule

    var body: some View {
        ZStack {
            if let id = module.detailID, let agent = module.snapshot.agents.first(where: { $0.id == id }),
               let subID = module.subagentID, let sub = agent.subagents.first(where: { $0.id == subID }) {
                SubagentDetailCard(module: module, parent: agent, sub: sub)
                    .transition(.blurSlide(x: 18))
            } else if let id = module.detailID, let agent = module.snapshot.agents.first(where: { $0.id == id }) {
                SessionDetailCard(module: module, agent: agent)
                    .transition(.blurSlide(x: 18))
            } else if module.showsLoops, let name = module.selectedLoop, let loop = module.loops.first(where: { $0.name == name }) {
                LoopDetailCard(module: module, loop: loop)
                    .transition(.blurSlide(x: 18))
            } else if module.showsLoops {
                LoopsCard(module: module)
                    .transition(.blurSlide(y: 10))
            } else {
                HStack(spacing: 10) {
                    MainAgentCard(module: module)
                        .frame(width: 318)
                    SideCard(module: module)
                }
                .transition(.blurSlide(y: -10))
            }
        }
        .animation(Theme.snappy, value: module.showsLoops)
    }
}

/// The main agent leaning over the card's bottom edge, with its steps.
private struct MainAgentCard: View {
    let module: AgentsModule
    @Environment(\.notch) private var notch

    var body: some View {
        let main = module.main
        HoverRow(cornerRadius: 20, restOpacity: 0.055, hoverOpacity: 0.085,
                 help: main.map { "Details for \($0.displayTitle)" } ?? "") {
            if let main { module.openDetail(main) }
        } label: {
            ZStack(alignment: .bottomLeading) {
                if let main, module.avatarMood(of: main) != .idle {
                    // A soft glow in the agent's color while it does something.
                    Circle()
                        .fill(module.color(of: main).opacity(0.32))
                        .frame(width: 120, height: 120)
                        .blur(radius: 34)
                        .frame(width: 118, alignment: .center)
                        .frame(maxHeight: .infinity, alignment: .center)
                }
                // The figure sits centred in its column, not stranded at the bottom.
                MainFigure(module: module, height: 112, emergeOnAppear: false)
                    .frame(width: 118, height: 124, alignment: .bottom)
                    .frame(maxHeight: .infinity, alignment: .center)
                    .notchMatched("agents.main", in: notch.namespace)
                text(main)
                    .padding(.leading, 124)
                    .padding([.top, .trailing], 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .accessibilityLabel(main.map { "\($0.project): \(module.line(for: $0))" } ?? "No agents running")
    }

    @ViewBuilder private func text(_ main: AgentSnapshot.Agent?) -> some View {
        if let main {
            let mood = module.avatarMood(of: main)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(main.displayTitle)
                        .font(Theme.font(14, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if module.showsToolBadges { ToolBadge(provider: main.provider) }
                }
                .lineLimit(1)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(module.secondary(for: main, now: context.date))
                        .font(Theme.font(12).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .help("\(main.model ?? "model unknown") · effort \(main.effort ?? "unknown")")
                .padding(.top, 1)
                if let summary = AgentSnapshot.Subagent.summary(main.subagents, earlier: main.earlierSubagents) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.turn.down.right").font(.system(size: 9.5, weight: .semibold))
                        Text(summary.replacingOccurrences(of: "Subagents: ", with: "") + " subagents")
                    }
                    .lineLimit(1)
                    .font(Theme.font(11.5, .medium))
                    .foregroundStyle(main.subagents.contains { $0.status == .running } ? Theme.accent : Theme.textTertiary)
                    .padding(.top, 3)
                }
                StepList(steps: main.steps, busy: main.isBusy)
                    .padding(.top, 9)
                Spacer(minLength: 0)
                switch mood {
                case .finished:
                    Label("Done", systemImage: "checkmark")
                        .font(Theme.font(12, .semibold))
                        .foregroundStyle(Theme.ok)
                        .padding(.bottom, 12)
                case .yourTurn:
                    Text("Your turn")
                        .font(Theme.font(12, .medium))
                        .foregroundStyle(Theme.waiting)
                        .padding(.bottom, 12)
                default:
                    EmptyView()
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 5) {
                Text("No agents running")
                    .font(Theme.font(14, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Sessions show up here as soon as Claude Code works on this Mac.")
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The last steps of a session: earlier ones dim, the current one bright.
private struct StepList: View {
    let steps: [SessionStep]
    let busy: Bool

    var body: some View {
        let shown = Array(steps.suffix(3))
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(shown.enumerated()), id: \.offset) { index, step in
                let isCurrent = index == shown.count - 1
                // A fixed 16 pt icon column, centred on the first line's cap height; same
                // symbol size for every step, so nothing shifts as steps move up.
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: Self.symbol(step.kind))
                        .font(.system(size: 11, weight: .medium))
                        .imageScale(.medium)
                        .frame(width: 16, alignment: .center)
                    Text(step.text)
                        .font(Theme.font(isCurrent ? 13 : 12, isCurrent ? .medium : .regular))
                        .lineLimit(isCurrent ? 2 : 1)
                        .shimmering(busy && isCurrent)
                }
                .foregroundStyle(isCurrent ? Theme.textPrimary : Theme.textTertiary)
                .transition(.blurSlide(y: 8))
            }
        }
        .animation(Theme.snappy, value: steps)
    }

    static func symbol(_ kind: SessionStep.Kind) -> String {
        switch kind {
        case .shell: "terminal"
        case .edit: "square.and.pencil"
        case .read: "doc.text"
        case .search: "magnifyingglass"
        case .web: "globe"
        case .agent: "person.2"
        case .plan: "list.bullet"
        case .tool: "puzzlepiece"
        case .message: "text.bubble"
        }
    }
}

/// The other sessions and the main session's subagents as two-line chips; the loops below.
/// Sessions that ended in the last days: a click opens Terminal with `claude --resume`.
private struct RecentList: View {
    let module: AgentsModule

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Recent · click to resume")
                .font(Theme.font(11.5, .semibold)).foregroundStyle(Theme.textSecondary)
                .padding(.leading, 6).frame(height: 18)
            ForEach(Array(module.recent.prefix(4))) { session in
                HoverRow(cornerRadius: 8, help: "claude --resume in \(session.cwd)") {
                    module.resume(session)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.uturn.backward.circle")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(session.title).font(Theme.font(12, .medium)).foregroundStyle(Theme.textBody)
                            Text("\(session.project) · \(session.modified.formatted(.relative(presentation: .named)))")
                                .font(Theme.font(10.5)).foregroundStyle(Theme.textTertiary)
                        }
                        .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 32)
                }
            }
        }
    }
}

private struct SideCard: View {
    let module: AgentsModule

    private struct Chip: Identifiable {
        var id: String
        var character: String
        var mood: AvatarMood
        var title: String
        var line: String
        var tint: Color
        var help: String
        var agent: AgentSnapshot.Agent?
        var hue: Double = 0
        var level: PerformanceLevel?
        /// The full colorway when the character brings its own look for the level.
        var colorway: Colorway?
        var branch: String?
        /// Subagents: the parent's character, drawn smaller.
        var isSubagent = false
    }

    /// Rows of the side card: the main session's subagents under a small header, then each
    /// other session with its subagents nested below it.
    private enum Row: Identifiable {
        case header(AgentSnapshot.Agent)
        case chip(Chip)
        case sub(AgentSnapshot.Agent, AgentSnapshot.Subagent, last: Bool)
        case earlier(String, Int)

        var id: String {
            switch self {
            case .header(let agent): "h-\(agent.id)"
            case .chip(let chip): "c-\(chip.id)"
            case .sub(_, let sub, _): "s-\(sub.id)"
            case .earlier(let parent, _): "e-\(parent)"
            }
        }
    }

    private func chip(for agent: AgentSnapshot.Agent) -> Chip {
        var line = module.secondary(for: agent)
        if let summary = AgentSnapshot.Subagent.summary(agent.subagents, earlier: agent.earlierSubagents),
           agent.subagents.contains(where: { $0.status == .running }) {
            line = summary
        }
        return Chip(id: agent.id, character: module.character(of: agent), mood: module.avatarMood(of: agent),
                    title: agent.displayTitle, line: line, tint: module.color(of: agent),
                    help: "\(agent.displayTitle) · \(agent.project)\(agent.branch.map { " on \($0)" } ?? "")\n\(agent.model ?? "model unknown") · effort \(agent.effort ?? "unknown")",
                    agent: agent, hue: module.hue(of: agent), level: module.variantLevel(of: agent),
                    colorway: module.variantLevel(of: agent) == nil ? nil : module.colorway(of: agent),
                    branch: agent.branch)
    }

    /// In the side card: running subagents and those that finished in the last two hours; the
    /// rest count as earlier (the session's detail card lists the last five).
    private func nested(_ agent: AgentSnapshot.Agent) -> [Row] {
        let recent = agent.subagents.filter(\.isRecent)
        let earlier = agent.earlierSubagents + agent.subagents.count - recent.count
        var rows = recent.enumerated().map { index, sub in
            Row.sub(agent, sub, last: index == recent.count - 1 && earlier == 0)
        }
        if earlier > 0 { rows.append(.earlier(agent.id, earlier)) }
        return rows
    }

    private var rows: [Row] {
        var rows: [Row] = []
        if let main = module.main, !main.subagents.isEmpty {
            let subs = nested(main)
            // Only old ones: one quiet line, no header block.
            if subs.contains(where: { if case .sub = $0 { true } else { false } }) {
                rows.append(.header(main))
                rows += subs
            }
        }
        for agent in module.others {
            rows.append(.chip(chip(for: agent)))
            rows += nested(agent)
        }
        return rows
    }

    var body: some View {
        let rows = rows
        NotchCard(padding: 10) {
            VStack(alignment: .leading, spacing: 8) {
                if rows.isEmpty, !module.recent.isEmpty {
                    RecentList(module: module)
                } else if rows.isEmpty {
                    LoopRows(module: module, limit: 3)
                } else {
                    ScrollView(.vertical) {
                        VStack(spacing: 4) {
                            ForEach(rows) { row in
                                switch row {
                                case .header(let agent):
                                    HStack(spacing: 6) {
                                        Text(agent.displayTitle).font(Theme.font(11.5, .semibold)).foregroundStyle(Theme.textSecondary)
                                        Text((AgentSnapshot.Subagent.summary(agent.subagents, earlier: agent.earlierSubagents) ?? "").replacingOccurrences(of: "Subagents: ", with: ""))
                                            .font(Theme.font(11)).foregroundStyle(Theme.textTertiary)
                                        Spacer(minLength: 0)
                                    }
                                    .lineLimit(1)
                                    .padding(.leading, 6)
                                    .frame(height: 18)
                                case .chip(let chip):
                                    chipView(chip, compact: true)
                                case .sub(let parent, let sub, let last):
                                    SubagentRow(module: module, parent: parent, sub: sub, last: last)
                                        .padding(.leading, 10)
                                case .earlier(_, let count):
                                    Text("+\(count) earlier")
                                        .font(Theme.font(11)).foregroundStyle(Theme.textTertiary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.leading, 34)
                                        .frame(height: 16)
                                }
                            }
                        }
                    }
                    .scrollIndicators(.never)
                    LoopStrip(module: module)
                }
            }
        }
    }

    private func chipView(_ chip: Chip, compact: Bool) -> some View {
        HoverRow(cornerRadius: 12, tint: chip.tint, restOpacity: 0.14, hoverOpacity: 0.24, help: chip.help) {
            if let agent = chip.agent { module.openDetail(agent) }
        } label: {
            HStack(alignment: .bottom, spacing: 6) {
                AvatarView(character: chip.character, mood: chip.mood,
                           height: (compact ? 36 : 40) * (chip.isSubagent ? 0.72 : 1),
                           colorway: chip.colorway ?? Colorway(hue: chip.hue), sink: 0.04, emergeOnAppear: false, level: chip.level)
                    .frame(width: compact ? 44 : 50, height: compact ? 40 : 46, alignment: .bottom)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(chip.title)
                            .font(Theme.font(12, .semibold))
                            .foregroundStyle(chip.tint.blended(with: .white, by: 0.45))
                        if module.showsToolBadges, let agent = chip.agent { ToolBadge(provider: agent.provider) }
                    }
                    Text(chip.line)
                        .font(Theme.font(11.5))
                        .foregroundStyle(Theme.textBody.opacity(0.85))
                }
                .lineLimit(1)
                .padding(.bottom, compact ? 5 : 7)
                Spacer(minLength: 0)
                if let agent = chip.agent, let label = module.contextLabel(of: agent) {
                    HStack(spacing: 4) {
                        if let pct = module.contextPercentage(of: agent) { ContextRing(percentage: pct) }
                        Text(label)
                            .font(Theme.font(11).monospacedDigit())
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.trailing, 10)
                    .padding(.bottom, compact ? 5 : 7)
                    .help(module.contextPercentage(of: agent) == nil
                          ? "Tokens in the context; the exact % needs Claude Code's status line (Set up usage)."
                          : "Context window used")
                }
            }
            .padding(.leading, 2)
            .frame(height: compact ? 40 : 46)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

/// "Claude" or "Codex" in the tool's tint: which tool runs a session, shown once more than one
/// tool has sessions, and in the header's plan limits.
struct ToolBadge: View {
    let provider: String

    var body: some View {
        let tint = AgentsModule.toolTint(of: provider)
        Text(AgentsModule.toolLabel(of: provider))
            .font(Theme.font(9.5, .bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .frame(height: 15)
            .background(tint.opacity(0.16), in: Capsule())
            .fixedSize()
            .help(AgentsModule.toolName(of: provider))
            .accessibilityLabel(AgentsModule.toolName(of: provider))
    }
}

struct JobRow: View {
    let job: LaunchdJob

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(job.isRunning ? Theme.accent : job.lastExitStatus == 0 ? Theme.textTertiary : Theme.critical)
                .frame(width: 6, height: 6)
                .frame(width: 14)
            Text(job.label.replacingOccurrences(of: Runtime.launchdPrefix, with: ""))
                .font(Theme.font(12.5))
                .foregroundStyle(Theme.textBody)
            Spacer()
            Text(job.isRunning ? "running" : job.lastExitStatus == 0 ? "ok" : "exit \(job.lastExitStatus)")
                .font(Theme.font(12).monospacedDigit())
                .foregroundStyle(job.isRunning ? Theme.accent : job.lastExitStatus == 0 ? Theme.textSecondary : Theme.critical)
        }
        .frame(height: 22)
    }
}

// MARK: - Shimmer

/// A light sweep over the active step. Core Animation moves the gradient (window server), so
/// SwiftUI does no per-frame work; inactive steps get nothing at all.
private struct Shimmer: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if active && !reduceMotion {
            content.overlay {
                ShimmerLayer()
                    .mask(content)
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            }
        } else {
            content
        }
    }
}

private struct ShimmerLayer: NSViewRepresentable {
    func makeNSView(context: Context) -> ShimmerView { ShimmerView() }
    func updateNSView(_ view: ShimmerView, context: Context) {}
}

final class ShimmerView: NSView {
    private let gradient = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        gradient.colors = [NSColor.clear.cgColor, NSColor.white.withAlphaComponent(0.55).cgColor, NSColor.clear.cgColor]
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.addSublayer(gradient)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let width = bounds.width * 0.45
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = CGRect(x: -width, y: 0, width: width, height: bounds.height)
        CATransaction.commit()
        gradient.removeAllAnimations()
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = -width / 2
        sweep.toValue = bounds.width + width / 2
        sweep.duration = 2.2
        sweep.repeatCount = .infinity
        gradient.add(sweep, forKey: "sweep")
    }
}

extension View {
    func shimmering(_ active: Bool) -> some View { modifier(Shimmer(active: active)) }
}
