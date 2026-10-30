import AppKit
import NotchCore
import SwiftUI

/// Previews: `--preview <name>` shows the real views with made-up data, for screenshots and
/// recordings. `--sample-data` is the same data as a test mode you can click through.
///
///     --preview tour                       all four features, about 28 s, then quits
///     --preview np-compact | np-peek | np-expanded | np-sneak
///     --preview capture-empty | capture-typed | capture-dictate | capture-sent
///     --preview loops-strip | loops-timeline | loops-sneak
///     --preview quota | quota-warn
///     --preview music-compact | music-peek | ears-crowded | sizes
///     --preview music-agents | crowded-sneak
///
/// Nothing here runs without a flag. All names and titles are made up.
@MainActor
final class PreviewDirector {
    static let names = ["usage", "usage-detail", "np-output", "r6-agents", "tour", "live-tour", "live-agents", "live-detail", "agents-compact", "loops-list", "loop-detail", "np-compact", "np-peek", "np-expanded", "np-sneak",
                        "capture-empty", "capture-typed", "capture-dictate", "capture-sent", "tara-always", "shelf-tara", "tara-eyes", "tara-eyes-round",
                        "loops-strip", "loops-timeline", "loops-sneak", "quota", "quota-warn",
                        "watch-peek", "watch-sneak", "watch-summary", "providers", "approval-codex", "extras", "media-compact", "media-peek", "limit-sneak", "shell-sneak",
                        "battery-sneak", "capture-event", "setup-consent", "setup-done",
                        "music-compact", "music-peek", "ears-crowded", "sizes",
                        "music-agents", "crowded-sneak",
                        // Media strand: synced lyrics in the panel and on hover, the mixer.
                        "np-lyrics", "np-peek-lyrics", "np-mixer",
                        // Strand agents.
                        "agents-more", "approval-cursor", "setup-agents",
                        // Tara's memory: paused, with the switch in the System tab and the badge beside the tabs.
                        "memory-paused", "memory-settings", "memory-settings-paused",
                        // The memory map with a made-up memory: settling, a search, a meeting's and a note's
                        // details, the graph settings.
                        "memory-map", "memory-map-search", "memory-map-detail", "memory-map-note", "memory-map-settings",
                        // Plan limits in the agents header: one tool, two, one gone quiet; with the popover.
                        "limits-one", "limits-two", "limits-stale", "limits-popover", "limits-popover-stale"]

    let notch: NotchController
    let agents: AgentsModule
    let music: NowPlayingModule
    var system: SystemModule?

    init(notch: NotchController, agents: AgentsModule, music: NowPlayingModule) {
        self.notch = notch
        self.agents = agents
        self.music = music
    }

    /// Mock agents: one working, one waiting for the user, one resting; loops with one running and
    /// one failed.
    static func snapshot(now: Date = Date(), agentsActive: Bool) -> AgentSnapshot {
        func step(_ kind: SessionStep.Kind, _ text: String) -> SessionStep { SessionStep(kind: kind, text: text) }
        var snapshot = AgentSnapshot()
        snapshot.agents = [
            .init(id: "preview-main", project: "notch", title: "Design preview", cwd: NSHomeDirectory(), pid: nil,
                  isBusy: agentsActive, since: now.addingTimeInterval(agentsActive ? -7 * 60 : -25 * 60),
                  steps: [step(.read, "Reading the feature analysis"), step(.edit, "Editing NowPlayingModule.swift"),
                          step(.shell, "Run unit tests")], subagents: [], branch: "r4-design", started: now.addingTimeInterval(-90 * 60)),
            .init(id: "preview-cal", project: "notch", title: "Calendar redesign", cwd: NSHomeDirectory(), pid: nil,
                  isBusy: agentsActive, since: now.addingTimeInterval(-2 * 60),
                  steps: [step(.edit, "Editing CalendarModule.swift")], subagents: [], branch: "r5-design",
                  started: now.addingTimeInterval(-40 * 60)),
            .init(id: "preview-api", project: "api-server", title: "Rate limits", cwd: NSHomeDirectory(), pid: nil,
                  isBusy: false, since: now.addingTimeInterval(agentsActive ? -3 * 60 : -40 * 60),
                  steps: [step(.message, "Done, the build is green.")], subagents: [], branch: "main"),
            .init(id: "preview-notes", project: "notes", title: "Weekly review", cwd: NSHomeDirectory(), pid: nil,
                  isBusy: false, since: now.addingTimeInterval(-52 * 60), steps: [], subagents: []),
        ]
        let start = Calendar.current.startOfDay(for: now)
        func at(_ hour: Double) -> Date { start.addingTimeInterval(hour * 3600) }
        func past(_ hour: Double, _ status: LoopRun.Status) -> LoopTimeline.Slot { .init(at: at(hour), status: status) }
        func next(_ hour: Double) -> LoopTimeline.Slot { .init(at: at(hour), status: nil) }
        let today = AgentScanner.day(now)
        func entry(_ loop: String, _ status: LoopRun.Status, _ note: String) -> LoopRun {
            LoopRun(day: today, loop: loop, status: status, note: note)
        }
        let hourNow = now.timeIntervalSince(start) / 3600
        var loops: [AgentSnapshot.LoopStatus] = [
            .init(name: "morning-brief", last: entry("morning-brief", .ok, "delivered yesterday"), nextRun: now.addingTimeInterval(60),
                  isLate: false, slots: [past(6.5, .ok), next(hourNow - 0.01), next(22.5)]),
            .init(name: "inbox-sorter", last: entry("inbox-sorter", .ok, "4 sorted"), nextRun: at(15),
                  isLate: false, slots: [past(3, .ok), hourNow > 15 ? past(15, .ok) : next(15)]),
            .init(name: "meeting-notes", last: entry("meeting-notes", .ok, "2 meetings summarised"), nextRun: nil,
                  isLate: false, slots: [past(5.5, .ok)]),
            .init(name: "release-notes", last: entry("release-notes", .ok, "nothing new"), nextRun: nil,
                  isLate: false, slots: [past(6, .ok)]),
            .init(name: "news-digest", last: entry("news-digest", .degraded, "3 sources"), nextRun: nil,
                  isLate: false, slots: [past(7, .degraded)]),
            .init(name: "link-check", last: entry("link-check", .fail, "3 broken links"), nextRun: nil,
                  isLate: false, slots: [past(4, .fail)]),
        ]
        // Morning brief is running; each loop has a last message like the real outboxes.
        loops[0].isRunning = true
        loops[0].runningSince = now.addingTimeInterval(-4 * 60)
        loops[0].progress = 0.64
        for index in loops.indices {
            loops[index].history = [loops[index].last].compactMap { $0 }
            loops[index].outboxDate = now.addingTimeInterval(-3 * 3600)
        }
        loops[0].outbox = "Morning brief\n\nTop 3:\n1. Design review at 12:30\n2. Launch post (due tomorrow)\n3. Book the offsite flights"
        snapshot.loops = loops
        return snapshot
    }

    /// Claude Code and Codex sessions side by side: the same project shares its character.
    static func providerSnapshot(now: Date = Date()) -> AgentSnapshot {
        func step(_ kind: SessionStep.Kind, _ text: String) -> SessionStep { SessionStep(kind: kind, text: text) }
        var snapshot = snapshot(now: now, agentsActive: true)
        let harbor = NSHomeDirectory() + "/projects/harbor", api = NSHomeDirectory() + "/projects/api-server"
        var lovelace = SubagentProgress()
        lovelace.task = "export tests"
        lovelace.startedAt = now.addingTimeInterval(-4 * 60)
        lovelace.lastDate = now
        snapshot.agents = [
            .init(id: "pv-claude", project: "harbor", title: "Speed up the report page", cwd: harbor, isBusy: true,
                  since: now.addingTimeInterval(-9 * 60), steps: [step(.edit, "Editing ReportView.swift")],
                  branch: "perf/report", started: now.addingTimeInterval(-50 * 60), level: .high,
                  model: "claude-opus-5-5", effort: "high", contextPercentage: 38),
            .init(id: "codex:pv-codex", project: "harbor", title: "Flaky export test", cwd: harbor, isBusy: true,
                  since: now.addingTimeInterval(-4 * 60), steps: [step(.shell, "swift test --filter Export")],
                  subagents: [AgentSubagent(id: "codex:pv-sub", name: "Lovelace", step: "rg --files Tests", agentType: "codex",
                                            status: .running, modified: now, progress: lovelace)],
                  branch: "fix/export-test", started: now.addingTimeInterval(-20 * 60), level: .xhigh,
                  model: "gpt-6.1-sol", effort: "xhigh", contextTokens: 35_616, provider: CodexProvider.id, contextWindow: 475_000),
            .init(id: "codex:pv-api", project: "api-server", title: "Pagination for /tasks", cwd: api, isBusy: false,
                  since: now.addingTimeInterval(-6 * 60), steps: [step(.message, "Pagination is in; 14 tests pass.")],
                  branch: "main", level: .medium, model: "gpt-6.1-sol", effort: "medium",
                  contextTokens: 118_000, provider: CodexProvider.id, contextWindow: 475_000),
            .init(id: "pv-api-claude", project: "api-server", title: "Rate limits", cwd: api, isBusy: false,
                  since: now.addingTimeInterval(-38 * 60), steps: [], branch: "main", level: .medium,
                  model: "claude-opus-5-5", effort: "medium", contextPercentage: 21),
        ]
        return snapshot
    }

    /// Every tool at once: Claude Code and Codex, plus Cursor waiting for an approval, Copilot CLI
    /// working, Gemini CLI waiting at its own prompt and opencode resting.
    static func moreProvidersSnapshot(now: Date = Date()) -> AgentSnapshot {
        func step(_ kind: SessionStep.Kind, _ text: String) -> SessionStep { SessionStep(kind: kind, text: text) }
        var snapshot = providerSnapshot(now: now)
        let home = NSHomeDirectory()
        snapshot.agents = Array(snapshot.agents.prefix(2)) + [
            .init(id: "cursor:pv-cursor", project: "atlas", title: "Migrate the settings store", cwd: home + "/projects/atlas",
                  isBusy: false, since: now.addingTimeInterval(-40), steps: [step(.shell, "npm run migrate -- --env staging")],
                  model: "composer-2", provider: CursorProvider.id, needsYou: "Approve: npm run migrate -- --env staging"),
            .init(id: "copilot:pv-copilot", project: "api-server", title: "Add pagination to /tasks", cwd: home + "/projects/api-server",
                  isBusy: true, since: now.addingTimeInterval(-3 * 60), steps: [step(.edit, "Editing tasks.ts")],
                  model: "gpt-6.1", provider: CopilotProvider.id),
            .init(id: "gemini:pv-gemini", project: "harbor", title: "Report page speed", cwd: home + "/projects/harbor",
                  isBusy: false, since: now.addingTimeInterval(-90), steps: [step(.shell, "rm -rf build")],
                  model: "gemini-3-pro", provider: GeminiProvider.id, needsYou: "Allow shell command: rm -rf build?"),
            .init(id: "opencode:pv-opencode", project: "notes", title: "Tidy the inbox script", cwd: home + "/projects/notes",
                  isBusy: false, since: now.addingTimeInterval(-12 * 60), steps: [step(.message, "Done; the script runs in 0.4 s.")],
                  provider: OpencodeProvider.id),
        ]
        return snapshot
    }

    /// Sessions of one project on different effort levels, plus one in another project.
    static func projectSnapshot(now: Date = Date()) -> AgentSnapshot {
        func step(_ kind: SessionStep.Kind, _ text: String) -> SessionStep { SessionStep(kind: kind, text: text) }
        var snapshot = snapshot(now: now, agentsActive: true)
        let notes = NSHomeDirectory() + "/projects/notes"
        snapshot.agents = [
            .init(id: "s-notch", project: "notes", title: "Island polish", cwd: notes, pid: nil, isBusy: true,
                  since: now.addingTimeInterval(-6 * 60), steps: [step(.edit, "Editing AgentsModule.swift")], subagents: [],
                  started: now.addingTimeInterval(-5 * 3600), level: .max, model: "claude-opus-5-5", effort: "max",
                  contextPercentage: 43),
            .init(id: "s-cv", project: "notes", title: "Portfolio site", cwd: notes, pid: nil, isBusy: false,
                  since: now.addingTimeInterval(-3 * 60), steps: [step(.message, "The hero section is in.")], subagents: [],
                  started: now.addingTimeInterval(-3 * 3600), level: .high, model: "claude-opus-5-5", effort: "high",
                  contextPercentage: 76),
            .init(id: "s-sim", project: "notes", title: "Press kit templates", cwd: notes, pid: nil, isBusy: false,
                  since: now.addingTimeInterval(-41 * 60), steps: [], subagents: [],
                  started: now.addingTimeInterval(-2 * 3600), level: .medium, model: "claude-opus-5-5", effort: "medium",
                  contextPercentage: 93),
            .init(id: "s-ml", project: "notes", title: "Pricing page copy", cwd: notes, pid: nil, isBusy: false,
                  since: now.addingTimeInterval(-95 * 60), steps: [], subagents: [],
                  started: now.addingTimeInterval(-1 * 3600), level: .low, model: "claude-haiku-5-5", effort: "low"),
            .init(id: "s-mt", project: "api-server", title: "Tasks endpoint", cwd: NSHomeDirectory() + "/projects/api-server",
                  pid: nil, isBusy: false, since: now.addingTimeInterval(-12 * 60), steps: [], subagents: [], branch: "main",
                  started: now.addingTimeInterval(-30 * 60), level: .medium, model: "claude-opus-5-5", effort: "medium"),
        ]
        return snapshot
    }

    /// A session with three subagents (one running, one done, one failed) and another session
    /// with one running subagent. Neutral names.
    static func subagentSnapshot(now: Date = Date()) -> AgentSnapshot {
        func step(_ kind: SessionStep.Kind, _ text: String) -> SessionStep { SessionStep(kind: kind, text: text) }
        func sub(_ id: String, _ name: String, _ status: SubagentProgress.Status, task: String, steps: [SessionStep],
                 last: String?, report: String? = nil, tools: Int, tokens: Int, minutes: Double) -> AgentSnapshot.Subagent {
            var progress = SubagentProgress()
            progress.task = task
            progress.steps = steps
            progress.lastText = last
            progress.result = report
            progress.toolUses = tools
            progress.outputTokens = tokens
            progress.startedAt = now.addingTimeInterval(-minutes * 60)
            progress.lastDate = status == .running ? now : now.addingTimeInterval(-minutes * 20)
            progress.errored = status == .failed
            return AgentSnapshot.Subagent(id: id, name: name, step: status == .running ? steps.last?.text : nil,
                                          agentType: "general-purpose", status: status,
                                          modified: progress.lastDate, progress: progress)
        }
        var snapshot = levelSnapshot(main: .max, now: now)
        snapshot.agents[0].subagents = [
            sub("sa-1", "Rewrite the importer", .running, task: "Rewrite the CSV importer so dates in either format parse, with tests.",
                steps: [step(.read, "Reading importer.swift"), step(.edit, "Editing importer.swift"), step(.shell, "Run the tests")],
                last: "Two formats parse now; checking the third.", tools: 23, tokens: 4_800, minutes: 6),
            sub("sa-2", "Audit the docs", .done, task: "Find every outdated command in the docs and fix it.",
                steps: [step(.search, "Searching for \u{201C}swift run\u{201D}"), step(.edit, "Editing README.md")],
                last: "All fixed.", report: "Seven outdated commands fixed in four files.\nThe install section now matches the build script.\nNothing else needed a change.",
                tools: 31, tokens: 6_200, minutes: 14),
            sub("sa-3", "Profile the scanner", .failed, task: "Measure the agent scan on a large transcript and report where the time goes.",
                steps: [step(.shell, "Run the benchmark")], last: "API Error: the request timed out.", tools: 4, tokens: 900, minutes: 3),
        ]
        snapshot.agents[0].earlierSubagents = 2
        snapshot.agents[1].subagents = [
            sub("sa-4", "Check the links", .running, task: "Check every link on the site and list the broken ones.",
                steps: [step(.web, "Reading example.com")], last: "12 of 40 checked.", tools: 12, tokens: 1_300, minutes: 2),
        ]
        return snapshot
    }

    static func resetTime(now: Date = Date()) -> Date {
        let start = Calendar.current.startOfDay(for: now)
        let candidate = start.addingTimeInterval(18 * 3600)
        return candidate > now ? candidate : start.addingTimeInterval(23 * 3600)
    }

    /// One session per effort level, all at work; `main` leads the panel.
    static func levelSnapshot(main: PerformanceLevel, now: Date = Date()) -> AgentSnapshot {
        func step(_ text: String) -> SessionStep { SessionStep(kind: .edit, text: text) }
        var snapshot = snapshot(now: now, agentsActive: true)
        let titles: [PerformanceLevel: String] = [.low: "Fix a typo", .medium: "Docs refresh", .high: "Calendar redesign",
                                                  .xhigh: "Sync engine", .max: "Island polish", .ultra: "Migration plan"]
        let order = [main] + PerformanceLevel.allCases.filter { $0 != main }
        snapshot.agents = order.enumerated().map { index, level in
            AgentSnapshot.Agent(id: "lv-\(level.rawValue)", project: "notes", title: titles[level], cwd: NSHomeDirectory(),
                                pid: nil, isBusy: true, since: now.addingTimeInterval(-Double(index + 1) * 90),
                                steps: [step("Editing AgentsModule.swift")], subagents: [],
                                started: now.addingTimeInterval(-Double(index + 1) * 600), level: level,
                                model: "claude-opus-5-5", effort: level.rawValue)
        }
        return snapshot
    }

    /// `levels:<character>[:<level>[:compact|peek]]`: every effort level with one character.
    private func runLevels(_ name: String) {
        let parts = name.split(separator: ":").map(String.init)
        if parts.count > 1 { agents.cast.previewCharacter = parts[1] }
        let main = parts.count > 2 ? PerformanceLevel(rawValue: parts[2]) ?? .max : .max
        agents.usePreview(Self.levelSnapshot(main: main))
        agents.previewPlan = StatusSnapshot(
            sessionID: "preview", fiveHour: .init(usedPercentage: 62, resetsAt: Date().addingTimeInterval(2 * 3600 + 14 * 60)),
            sevenDay: .init(usedPercentage: 48, resetsAt: Date().addingTimeInterval(4 * 86_400)), capturedAt: Date())
        let state = parts.count > 3 ? parts[3] : "expanded"
        Task {
            await pause(0.8)
            switch state {
            case "compact": break
            case "peek": notch.tourPeek()
            default: notch.expand(.agents, pinned: true)
            }
        }
    }

    /// About 14 s, the panel open: one session changes state every 2 s (and once flips twice within a second).
    private func moodTour() async {
        func session(busy: Bool, since: TimeInterval, step: SessionStep.Kind = .edit) -> AgentSnapshot {
            var snapshot = Self.levelSnapshot(main: .high)
            snapshot.agents[0].isBusy = busy
            snapshot.agents[0].since = Date().addingTimeInterval(-since)
            snapshot.agents[0].steps = [SessionStep(kind: step, text: busy ? "Editing AgentsModule.swift" : "Done.")]
            return snapshot
        }
        agents.usePreview(session(busy: false, since: 600, step: .message))
        await pause(0.8)
        notch.expand(.agents, pinned: true)
        await pause(2.0)
        agents.usePreview(session(busy: true, since: 5))                     // working
        await pause(2.0)
        agents.usePreview(session(busy: true, since: 5, step: .shell))       // a tool: thinking
        await pause(2.0)
        if let main = agents.main { agents.markFinished(main.id) }          // done
        agents.usePreview(session(busy: false, since: 1, step: .message))
        await pause(2.6)
        agents.usePreview(session(busy: true, since: 1))                     // flip …
        await pause(0.4)
        agents.usePreview(session(busy: false, since: 1, step: .message))   // … and back: no flicker
        await pause(2.2)
        agents.usePreview(session(busy: false, since: 3600, step: .message)) // long idle: asleep
        await pause(2.4)
        NSApp.terminate(nil)
    }

    /// About 14 s, the panel open throughout: Astra leads at every effort level, then finishes.
    private func astraTour() async {
        await pause(0.8)
        notch.expand(.agents, pinned: true)
        for level in PerformanceLevel.allCases {
            await pause(1.6)
            withAnimation(Theme.snappy) { agents.usePreview(Self.levelSnapshot(main: level)) }
        }
        await pause(1.4)
        if let main = agents.main { agents.markFinished(main.id) }
        await pause(2.4)
        NSApp.terminate(nil)
    }

    /// About 18 s: the cat through the effort levels (its eyes change), then Astra (its colours).
    private func levelsTour() async {
        agents.cast.previewCharacter = "cat"
        agents.usePreview(Self.levelSnapshot(main: .low))
        await pause(1.2)
        notch.tourPeek()
        await pause(1.6)
        notch.expand(.agents, pinned: true)
        for level in PerformanceLevel.allCases {
            await pause(1.3)
            withAnimation(Theme.snappy) { agents.usePreview(Self.levelSnapshot(main: level)) }
        }
        await pause(1.4)
        notch.collapse()
        await pause(0.8)
        agents.cast.previewCharacter = "astra"
        agents.usePreview(Self.levelSnapshot(main: .low))
        notch.tourPeek()
        await pause(1.4)
        notch.expand(.agents, pinned: true)
        for level in PerformanceLevel.allCases.dropFirst() {
            await pause(1.0)
            withAnimation(Theme.snappy) { agents.usePreview(Self.levelSnapshot(main: level)) }
        }
        await pause(1.2)
        notch.collapse()
        await pause(1.0)
        NSApp.terminate(nil)
    }

    /// Made-up load: a busy minute on the CPU, a little GPU, memory with or without pressure.
    func useSystemSample(tight: Bool) {
        let cpu: [Double] = (0..<SystemModule.historyLength).map { (i: Int) -> Double in
            let wave: Double = 0.12 * sin(Double(i) / 5)
            let busy: Double = i > 40 ? 0.35 : 0
            return 0.18 + wave + busy
        }
        let gpu: [Double] = (0..<SystemModule.historyLength).map { (i: Int) -> Double in 0.06 + 0.05 * sin(Double(i) / 3) }
        let gb: UInt64 = 1_073_741_824
        let memory = MemoryStats(total: 24 * gb, used: (tight ? 21 : 15) * gb, app: (tight ? 14 : 9) * gb, wired: 3 * gb,
                                 compressed: (tight ? 4 : 2) * gb, swapUsed: (tight ? 6 : 1) * gb,
                                 pressure: tight ? .warn : .normal)
        let mb: UInt64 = 1_048_576
        let apps = [
            AppUsage(key: "/Applications/Google Chrome.app", name: "Google Chrome", bundlePath: "/Applications/Google Chrome.app",
                     cpu: 0.42, memory: 3_300 * mb, processes: 23),
            AppUsage(key: "claude-code", name: "Claude Code", bundlePath: nil, cpu: 0.31, memory: 1_200 * mb, processes: 4),
            AppUsage(key: "/Applications/Xcode.app", name: "Xcode", bundlePath: "/Applications/Xcode.app",
                     cpu: 0.12, memory: 2_100 * mb, processes: 3),
            AppUsage(key: "/System/Applications/Music.app", name: "Music", bundlePath: "/System/Applications/Music.app",
                     cpu: 0.04, memory: 380 * mb, processes: 1),
            AppUsage(key: "WindowServer", name: "WindowServer", bundlePath: nil, cpu: 0.03, memory: 900 * mb, processes: 1),
        ]
        // A download that picks up in the last minute: about 0.3 to 2.4 MB/s.
        let network: [Double] = (0..<SystemModule.historyLength).map { (i: Int) -> Double in
            Double(mb) * (0.3 + 0.2 * sin(Double(i) / 4) + (i > 34 ? 1.9 : 0))
        }
        system?.usePreview(cpu: cpu, gpu: gpu, memory: memory, apps: apps, network: network, upload: 180 * 1024)
    }

    func run(_ name: String) {
        // The notch's look, as a suffix to any name: `+details` the richer ears (Settings ›
        // Details beside the notch), `+reading` / `+off` screen context reading or not (Tara awake
        // or resting), `+paused` Tara's memory paused. Without, the quiet look.
        let parts = name.split(separator: "+").map(String.init)
        notch.model.detailedEars = parts.contains("details")
        notch.model.previewScreenReading = parts.contains("reading") ? true : parts.contains("off") ? false : nil
        if parts.contains("paused") { notch.model.memoryPaused = true }
        let name = parts.first ?? name
        if name.hasPrefix("levels:") { runLevels(name); return }
        if name.hasPrefix("palette") || name.hasPrefix("inbox") { runCommand(name); return }
        if name.hasPrefix("system") {
            // system | system:tight | system:compact | system:peek | system:peek-after (hovered
            // after the System tab was the last one open, memory tight, a session waiting)
            let parts = name.split(separator: ":").map(String.init)
            let state = parts.count > 1 ? parts[1] : "expanded"
            useSystemSample(tight: state != "expanded")
            agents.usePreview(Self.snapshot(agentsActive: state == "peek-after"))
            Task {
                await pause(0.8)
                switch state {
                case "compact", "agents": break
                case "peek": notch.tourPeek()
                case "peek-after":
                    notch.model.module = .system
                    notch.tourPeek()
                default: notch.expand(.system, pinned: true)
                }
            }
            return
        }
        if name.hasPrefix("pack-sheet") { PackSheet.show(name); return }
        if name == "memory-paused" {
            // Tara's memory paused: the System tab's switch lit, the badge beside the tabs.
            useSystemSample(tight: false)
            agents.usePreview(Self.snapshot(agentsActive: false))
            system?.battery = BatteryState(percent: 82, charging: true, pluggedIn: true, minutesLeft: 35)
            system?.memoryPaused = true
            notch.model.memoryPaused = true
            Task {
                await pause(0.8)
                notch.expand(.system, pinned: true)
            }
            return
        }
        if name == "extras" {
            // Battery, keep awake, the camera in use by a call, a long build in the terminal.
            useSystemSample(tight: false)
            agents.usePreview(Self.snapshot(agentsActive: false))
            system?.battery = BatteryState(percent: 64, charging: true, pluggedIn: true, minutesLeft: 70)
            system?.keepAwake = true
            system?.usePreviewMedia(MediaUse(camera: true, microphone: true, app: "FaceTime"))
            system?.longCommands = [ShellActivity.Running(pid: 1, start: Date().addingTimeInterval(-134), cwd: "/Users/me/projects/harbor", command: "npm run build")]
            Task {
                await pause(0.8)
                notch.expand(.system, pinned: true)
            }
            return
        }
        if name.hasPrefix("lid-awake") {
            // lid-awake | lid-awake:until-off | :offer | :picker | :battery | :compact | :peek
            // | :agents (compact while agents work and a loop failed: the lid keeps the ears)
            let parts = name.split(separator: ":").map(String.init)
            let state = parts.count > 1 ? parts[1] : "on"
            useSystemSample(tight: false)
            if state == "agents" {
                agents.usePreview(Self.snapshot(agentsActive: true))
            } else {
                var snapshot = Self.snapshot(agentsActive: false)
                snapshot.agents = []
                snapshot.loops = []
                agents.usePreview(snapshot)
            }
            let plugged = state != "battery"
            system?.battery = BatteryState(percent: plugged ? 82 : 64, charging: plugged, pluggedIn: plugged, minutesLeft: plugged ? 35 : 240)
            system?.keepAwake = true
            let since = Date().addingTimeInterval(-19 * 60)
            switch state {
            case "offer": system?.usePreviewLid(.off)
            case "picker", "battery": system?.usePreviewLid(.off, picker: true)
            case "until-off": system?.usePreviewLid(.on(since: since, until: nil))
            default: system?.usePreviewLid(.on(since: since, until: since.addingTimeInterval(3 * 3600)))
            }
            Task {
                await pause(0.8)
                switch state {
                case "compact", "agents": break
                case "peek": notch.tourPeek()
                default: notch.expand(.system, pinned: true)
                }
            }
            return
        }
        if name == "music-agents" || name == "crowded-sneak" {
            // music-agents: agents working and waiting while music plays, ears as by default (no
            // note there: it belongs to the music tab and its peek). crowded-sneak: a status item right beside the
            // notch on the left; a sneak stays out of it and drops its right ear.
            agents.usePreview(Self.snapshot(agentsActive: true))
            music.start()
            if name == "crowded-sneak" {
                let half = notch.model.notchSize.width / 2
                notch.simulatedMenuBarItems = [-(half + 262) ... -(half + 8), half + 180 ... half + 204]
            }
            Task {
                await pause(1.0)
                if name == "crowded-sneak" {
                    notch.sneak(Sneak(visual: .symbol("checkmark.circle", tint: .ok), title: "npm run build",
                                      detail: "2 m 14 s", duration: 30), key: "shell")
                }
            }
            return
        }
        if name == "music-compact" || name == "music-peek" || name == "ears-crowded" || name == "sizes" {
            // music-compact | music-peek: Tara with her note in the leading ear, the cover in the
            // trailing one. ears-crowded: agents' ears with a long status item right beside the
            // notch on the left (as macOS places one when the right side is full): no ears there.
            // sizes: the large Calendar panel, then the compact Music panel, then back.
            var snapshot = Self.snapshot(agentsActive: true)
            if name != "ears-crowded" {
                snapshot.agents = []
                snapshot.loops = []
            }
            agents.usePreview(snapshot)
            music.start()
            if name == "ears-crowded" {
                let half = notch.model.notchSize.width / 2
                notch.simulatedMenuBarItems = [-(half + 262) ... -(half + 2), half + 180 ... half + 204]
            }
            Task {
                await pause(0.8)
                if name != "ears-crowded" { notch.model.earsMode = .always }
                switch name {
                case "music-peek": notch.tourPeek()
                case "sizes":
                    notch.expand(.calendar, pinned: true)
                    await pause(2.5)
                    notch.expand(.nowPlaying, pinned: true)
                    await pause(2.5)
                    notch.expand(.calendar, pinned: true)
                default: break
                }
            }
            return
        }
        if name == "np-peek-lyrics" {
            // Media strand: no agents, so the music holds the ears; the hover line sings along.
            agents.usePreview(AgentSnapshot())
            music.start()
            Task {
                await pause(0.8)
                notch.tourPeek()
            }
            return
        }
        if name == "media-compact" || name == "media-peek" {
            agents.usePreview(Self.snapshot(agentsActive: false))
            useSystemSample(tight: false)
            system?.usePreviewMedia(MediaUse(camera: true, microphone: true, app: "FaceTime"))
            Task {
                await pause(0.8)
                if name == "media-peek" { notch.tourPeek() }
            }
            return
        }
        if name == "limit-sneak" || name == "shell-sneak" || name == "battery-sneak" {
            agents.usePreview(Self.snapshot(agentsActive: false))
            Task {
                await pause(1.0)
                switch name {
                case "limit-sneak":
                    notch.sneak(Sneak(visual: .symbol("gauge.with.dots.needle.67percent", tint: .waiting), title: "Claude full at 14:20",
                                      detail: "82 %", duration: 8), key: "limit")
                case "shell-sneak":
                    notch.sneak(Sneak(visual: .symbol("checkmark.circle", tint: .ok), title: "npm run build",
                                      detail: "2 m 14 s", duration: 8), key: "shell")
                default:
                    notch.sneak(Sneak(visual: .symbol("bolt.fill", tint: .ok), title: "Charging",
                                      detail: "64 %", duration: 8), key: "battery")
                }
            }
            return
        }
        if name == "capture-event" {
            agents.usePreview(Self.snapshot(agentsActive: false))
            Task {
                await pause(0.8)
                notch.openCapture()
                await type("Call Ada tomorrow at 15:00")
            }
            return
        }
        if name == "agents-more" || name == "approval-cursor" {
            // Six tools side by side, the plan limits saying when they run out; or a Cursor prompt.
            agents.cast.previewCharacter = "astra"
            agents.usePreview(Self.moreProvidersSnapshot())
            let now = Date()
            agents.previewPlan = StatusSnapshot(
                sessionID: "preview", fiveHour: .init(usedPercentage: 62, resetsAt: now.addingTimeInterval(2 * 3600 + 14 * 60)),
                sevenDay: .init(usedPercentage: 48, resetsAt: now.addingTimeInterval(4 * 86_400)), capturedAt: now)
            agents.previewUsages = [AgentUsage(
                provider: CodexProvider.id, displayName: CodexProvider.displayName,
                primary: .init(usedPercent: 34, minutes: 300, resetsAt: now.addingTimeInterval(3 * 3600)),
                secondary: .init(usedPercent: 71, minutes: 10_080, resetsAt: now.addingTimeInterval(3 * 86_400)),
                plan: "plus", capturedAt: now)]
            let json = #"{"starnotch_provider":"cursor","starnotch_event":"beforeShellExecution","starnotch_pid":99999,"conversation_id":"pv-cursor","hook_event_name":"beforeShellExecution","workspace_roots":["/Users/me/projects/atlas"],"command":"npm run migrate -- --env staging","cwd":"/Users/me/projects/atlas"}"#
            Task {
                await pause(0.8)
                if name == "agents-more" {
                    notch.expand(.agents, pinned: true)
                } else if let request = ApprovalRequest.parse(Data(json.utf8), id: "preview") {
                    notch.model.approvals?.preview(request)
                }
            }
            return
        }
        if name.hasPrefix("limits-") {
            agents.cast.previewCharacter = "astra"
            agents.usePreview(Self.providerSnapshot())
            let now = Date()
            agents.previewPlan = StatusSnapshot(
                sessionID: "preview", fiveHour: .init(usedPercentage: 66, resetsAt: now.addingTimeInterval(2 * 3600 + 23 * 60)),
                sevenDay: .init(usedPercentage: 59, resetsAt: now.addingTimeInterval(4 * 86_400)), capturedAt: now)
            let stale = name.hasSuffix("stale")
            agents.previewUsages = name == "limits-one" ? [] : [AgentUsage(
                provider: CodexProvider.id, displayName: CodexProvider.displayName,
                primary: .init(usedPercent: 12, minutes: 300, resetsAt: now.addingTimeInterval(stale ? -3600 : 39 * 60)),
                secondary: .init(usedPercent: 3, minutes: 10_080, resetsAt: now.addingTimeInterval(5 * 86_400)),
                plan: "plus", capturedAt: now.addingTimeInterval(stale ? -26 * 3600 : -5 * 60))]
            agents.previewShowsLimits = name.hasPrefix("limits-popover")
            Task { await pause(0.8); notch.expand(.agents, pinned: true) }
            return
        }
        if name == "providers" || name == "approval-codex" {
            // Claude Code and Codex in the same projects, both tools' plan limits; or a Codex
            // permission prompt.
            agents.cast.previewCharacter = "astra"
            agents.usePreview(Self.providerSnapshot())
            let now = Date()
            agents.previewPlan = StatusSnapshot(
                sessionID: "preview", fiveHour: .init(usedPercentage: 62, resetsAt: now.addingTimeInterval(2 * 3600 + 14 * 60)),
                sevenDay: .init(usedPercentage: 48, resetsAt: now.addingTimeInterval(4 * 86_400)), capturedAt: now)
            agents.previewUsages = [AgentUsage(
                provider: CodexProvider.id, displayName: CodexProvider.displayName,
                primary: .init(usedPercent: 34, minutes: 300, resetsAt: now.addingTimeInterval(3 * 3600)),
                secondary: .init(usedPercent: 71, minutes: 10_080, resetsAt: now.addingTimeInterval(3 * 86_400)),
                plan: "plus", capturedAt: now)]
            let json = #"{"starnotch_provider":"codex","session_id":"pv-codex","turn_id":"t","cwd":"/Users/me/projects/harbor","hook_event_name":"PermissionRequest","model":"gpt-6.1-sol","tool_name":"Bash","tool_input":{"command":"npm run migrate -- --env staging","description":null}}"#
            Task {
                await pause(0.8)
                if name == "providers" {
                    notch.expand(.agents, pinned: true)
                } else if let request = ApprovalRequest.parse(Data(json.utf8), id: "preview") {
                    notch.model.approvals?.preview(request)
                }
            }
            return
        }
        if name == "approval" {
            // A made-up permission prompt from the main session.
            agents.cast.previewCharacter = "astra"
            agents.usePreview(Self.subagentSnapshot())
            let json = #"{"session_id":"lv-max","cwd":"/Users/me/projects/notes","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"git push --force-with-lease origin feature/island-polish","description":"Push the branch"}}"#
            Task {
                await pause(0.8)
                if let request = ApprovalRequest.parse(Data(json.utf8), id: "preview") {
                    notch.model.approvals?.preview(request)
                }
            }
            return
        }
        if name.hasPrefix("subagents") {
            // subagents | subagents:detail | subagents:parent
            agents.cast.previewCharacter = "astra"
            agents.usePreview(Self.subagentSnapshot())
            Task {
                await pause(0.8)
                notch.expand(.agents, pinned: true)
                await pause(0.6)
                if name.hasSuffix(":detail"), let main = agents.main, let sub = main.subagents.first {
                    agents.openSubagent(sub.id, of: main)
                } else if name.hasSuffix(":parent"), let main = agents.main {
                    agents.openDetail(main)
                }
            }
            return
        }
        if name.hasPrefix("mood-tour") {
            // mood-tour[:character]: the main session goes idle → working → done → your turn → idle.
            let parts = name.split(separator: ":").map(String.init)
            agents.cast.previewCharacter = parts.count > 1 ? parts[1] : "cat"
            Task { await moodTour() }
            return
        }
        if name == "astra-tour" {
            agents.cast.previewCharacter = "astra"
            agents.usePreview(Self.levelSnapshot(main: .low))
            agents.previewPlan = StatusSnapshot(
                sessionID: "preview", fiveHour: .init(usedPercentage: 62, resetsAt: Date().addingTimeInterval(2 * 3600 + 14 * 60)),
                sevenDay: .init(usedPercentage: 48, resetsAt: Date().addingTimeInterval(4 * 86_400)), capturedAt: Date())
            Task { await astraTour() }
            return
        }
        if name == "levels-tour" {
            agents.cast.previewCharacter = "cat"
            agents.usePreview(Self.levelSnapshot(main: .low))
            agents.previewPlan = StatusSnapshot(
                sessionID: "preview", fiveHour: .init(usedPercentage: 62, resetsAt: Date().addingTimeInterval(2 * 3600 + 14 * 60)),
                sevenDay: .init(usedPercentage: 48, resetsAt: Date().addingTimeInterval(4 * 86_400)), capturedAt: Date())
            music.start()
            Task { await levelsTour() }
            return
        }
        let agentsActive = !name.hasPrefix("np-")  // music shots: agents rest, so the music ears show
        if name == "live-agents" || name == "live-detail" {
            // Real sessions and quota, nothing mocked.
            agents.startStatus()
            Task {
                for _ in 0..<40 where agents.main == nil { await pause(0.25) }
                await pause(0.6)
                notch.expand(.agents, pinned: true)
                if name == "live-detail", let agent = agents.others.first ?? agents.main {
                    await pause(0.5)
                    agents.openDetail(agent)
                }
            }
            return
        }
        if name == "r6-agents" || name == "usage" || name == "usage-detail" {
            agents.usePreview(Self.projectSnapshot())
            agents.previewPlan = StatusSnapshot(
                sessionID: "preview", fiveHour: .init(usedPercentage: 62, resetsAt: Date().addingTimeInterval(2 * 3600 + 14 * 60)),
                sevenDay: .init(usedPercentage: 48, resetsAt: Date().addingTimeInterval(4 * 86_400)), capturedAt: Date())
            if name == "usage-detail" {
                Task {
                    await pause(1.2)
                    if let agent = agents.snapshot.agents.first(where: { $0.id == "s-cv" }) { agents.openDetail(agent) }
                }
            }
            Task { await pause(0.8); notch.expand(.agents, pinned: true) }
            return
        }
        if name == "live-tour" {
            // Real sessions, loops and quota; music and the capture send stay mocked.
            agents.startStatus()
            music.start()
            Task { await liveTour() }
            return
        }
        agents.usePreview(Self.snapshot(agentsActive: agentsActive))
        // A plan snapshot as Claude Code's status line reports it.
        let used: Double = name == "quota-warn" ? 86 : 62
        agents.previewPlan = StatusSnapshot(
            sessionID: "preview", fiveHour: .init(usedPercentage: used, resetsAt: Date().addingTimeInterval(2 * 3600 + 14 * 60)),
            sevenDay: .init(usedPercentage: 48, resetsAt: Date().addingTimeInterval(4 * 86_400)), capturedAt: Date())
        music.start()
        Task { await play(name) }
    }

    /// Test mode (`--sample-data`): sample agents, loops, plan and music; the island behaves as
    /// usual (hover, click, keyboard); the panels show no data from this Mac and nothing is written.
    func runSampleMode() {
        agents.usePreview(Self.projectSnapshot())
        useSystemSample(tight: false)
        agents.previewPlan = StatusSnapshot(
            sessionID: "sample", fiveHour: .init(usedPercentage: 38, resetsAt: Date().addingTimeInterval(3 * 3600 + 5 * 60)),
            sevenDay: .init(usedPercentage: 21, resetsAt: Date().addingTimeInterval(5 * 86_400)), capturedAt: Date())
        music.start()
    }

    private func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    private func play(_ name: String) async {
        await pause(0.8)
        switch name {
        case "np-compact", "agents-compact": break
        case "np-peek": notch.tourPeek()
        case "np-expanded": notch.expand(.nowPlaying, pinned: true)
        case "np-output":
            notch.expand(.nowPlaying, pinned: true)
            await pause(0.6)
            music.output.reload()
            withAnimation(Theme.snappy) { music.showsOutputs = true }
        case "np-sneak":
            await pause(0.4)
            music.next()
        case "np-lyrics": notch.expand(.nowPlaying, pinned: true)
        case "np-mixer":
            notch.expand(.nowPlaying, pinned: true)
            await pause(0.6)
            withAnimation(Theme.snappy) { music.showsMixer = true }
        case "capture-empty": notch.openCapture()
        // Settings › Notch › Tara beside the notch: Always, with nothing going on.
        case "tara-always": notch.model.taraAlways = true
        // A file dropped on Tara beside the shelf, waiting for Remember or Ask.
        case "shelf-tara":
            guard let tools = notch.model.module(.tools) as? ToolsModule else { break }
            tools.askAboutFile = tools.askAboutFile ?? { _ in }
            tools.tab = .shelf
            tools.taraFile = .waiting(URL(fileURLWithPath: "/tmp/Proposal.pdf"))
            notch.expand(.tools, pinned: true)
        case "capture-typed":
            notch.openCapture()
            await type("Angebot für Ada bis Freitag schicken")
        case "capture-dictate":
            notch.openCapture()
            await type("Frage an Grace: Budget schon", route: .question)
            notch.toggleCaptureMic()
        case "capture-sent":
            notch.openCapture()
            await type("Angebot für Ada bis Freitag schicken")
            await pause(0.3)
            notch.sendCapture()
        case "loops-strip": notch.expand(.agents, pinned: true)
        case "loop-detail":
            notch.expand(.agents, pinned: true)
            await pause(0.3)
            agents.openLoop("morning-brief")
        case "loops-list":
            notch.expand(.agents, pinned: true)
            await pause(0.3)
            agents.showsLoops = true
        case "loops-timeline":
            agents.loopsAsTimeline = true
            agents.showsLoops = true
            notch.expand(.agents, pinned: true)
            await pause(0.1)
            agents.showsLoops = true
        case "loops-sneak":
            await pause(0.4)
            agents.finishLoop("morning-brief")
        case "quota", "quota-warn": notch.expand(.agents, pinned: true)
        case "watch-peek":
            notch.setWatching(true)
            await pause(0.3)
            notch.tourPeek()
        case "watch-sneak":
            notch.setWatching(true)
            await pause(0.4)
            notch.sneak(Sneak(visual: .symbol("hand.raised.fill", tint: .waiting), title: "Approval waiting",
                              duration: 8), key: "approval", urgent: true)
        case "watch-summary":
            notch.setWatching(true)
            await pause(0.3)
            agents.finishLoop("morning-brief")
            music.next()
            await pause(0.5)
            notch.setWatching(false)
        case "tour": await tour()
        default:
            Log.app.error("Unknown preview \(name, privacy: .public); known: \(Self.names.joined(separator: ", "), privacy: .public)")
        }
    }

    /// Types like a person, a few characters at a time.
    private func type(_ text: String, route: QuickCapture.Route? = nil) async {
        await pause(0.5)
        guard let capture = notch.model.capture else { return }
        var typed = ""
        for character in text {
            typed.append(character)
            capture.text = typed
            try? await Task.sleep(for: .milliseconds(38))
        }
        if let route {
            await pause(0.25)
            Haptics.tick()
            withAnimation(Theme.snappy) { capture.route = route }
        }
    }

    /// Real data where possible, ~26 s: compact, hover, agents panel with project characters and
    /// quota, loops list and a loop's detail, quick capture with parsing, music, close.
    private func liveTour() async {
        for _ in 0..<40 where agents.main == nil { await pause(0.25) }
        await pause(1.6)
        notch.tourPeek()
        await pause(1.8)
        notch.expand(.agents, pinned: true)
        await pause(3.2)
        withAnimation(Theme.snappy) { agents.showsLoops = true }
        await pause(2.2)
        if let loop = agents.loops.first(where: { $0.outbox != nil }) { agents.openLoop(loop.name) }
        await pause(3.4)
        _ = agents.handleBack()
        _ = agents.handleBack()
        await pause(0.8)
        notch.collapse()
        await pause(0.7)
        notch.openCapture()
        await type("Send Ada Lovelace the offer by Friday 4pm")
        await pause(1.4)
        notch.sendCapture()
        await pause(2.6)
        notch.expand(.nowPlaying, pinned: true)
        await pause(2.6)
        music.next()
        await pause(1.8)
        notch.collapse()
        await pause(1.4)
        NSApp.terminate(nil)
    }

    /// All four features, ~28 s.
    private func tour() async {
        // 1 Now Playing: music ears while agents rest, peek, panel, track change by swipe.
        agents.usePreview(Self.snapshot(agentsActive: false))
        await pause(1.4)
        notch.tourPeek()
        await pause(1.6)
        notch.expand(.nowPlaying, pinned: true)
        await pause(2.0)
        music.next()                                  // swipe left on the card: next track
        await pause(1.8)
        notch.collapse()
        await pause(0.8)
        music.previous()                              // track change at rest: sneak
        await pause(3.0)

        // 2 Quick capture: ⌃⌥N, type, pick a route, dictate state, ↵, nod, close.
        notch.openCapture()
        await type("Ask Grace about the budget", route: .question)
        await pause(0.6)
        notch.sendCapture()
        await pause(2.6)

        // 3 Loops live: a loop runs, its strip, the timeline, then it finishes with a sneak.
        agents.usePreview(Self.snapshot(agentsActive: true))
        notch.expand(.agents, pinned: true)          // 4 quota ring sits in this header
        await pause(2.4)
        withAnimation(Theme.snappy) { agents.showsLoops = true }
        await pause(2.8)
        notch.collapse()
        await pause(0.9)
        agents.finishLoop("morning-brief")
        await pause(3.4)
        NSApp.terminate(nil)
    }
}
