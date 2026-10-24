import Testing
import TestSupport
@testable import NotchCore

/// Golden tests: anonymised copies of real Codex, Claude Code and Claude app files
/// (Tests/Fixtures). A format change in either tool shows up here first.
@Suite struct CodexProviderTests {
    let now = UTC.date("2026-10-20 12:00")

    @Test func paginatedSessionsFromThreadsAndRollouts() async throws {
        let home = Fixtures.codexHome(now: now)
        defer { Fixtures.remove(home) }
        let provider = CodexProvider(root: home, useProcesses: false)
        let scan = await provider.scan(now: now)
        #expect(scan.unsupported == nil)
        // The reviewer, the archived thread and yesterday's thread stay out; the subagent nests.
        #expect(scan.sessions.map(\.id) == ["codex:019a0001-0000-7000-8000-00000000b0d1", "codex:019a0001-0000-7000-8000-00000000c0de"])

        let working = scan.sessions[0]
        #expect(working.provider == "codex")
        #expect(working.title == "Flaky export test")
        #expect(working.project == "harbor")
        #expect(working.branch == "fix/export-test")
        #expect(working.isBusy)
        #expect(UTC.string(working.since) == "2026-10-20 11:52")
        #expect(working.steps.last?.text == "swift test --filter Export")
        #expect(working.steps.last?.kind == .shell)
        #expect(working.model == "gpt-6.1-sol")
        #expect(working.effort == "high")
        #expect(working.level == .high)
        #expect(working.contextWindow == 475_000)
        #expect(working.contextTokens == 35_616)
        #expect(working.subagents.map(\.name) == ["Lovelace"])
        #expect(working.subagents.first?.status == .running)
        #expect(working.subagents.first?.step == "swift test --filter Export")

        let done = scan.sessions[1]
        #expect(done.title == "CSV export for reports")
        #expect(!done.isBusy)
        #expect(done.branch == "main")
        #expect(done.subagents.isEmpty)
        #expect(UTC.string(done.since) == "2026-10-20 11:53")
    }

    @Test func planLimitsAsStatusShowsThem() async throws {
        let home = Fixtures.codexHome(now: now)
        defer { Fixtures.remove(home) }
        let provider = CodexProvider(root: home, useProcesses: false)
        _ = await provider.scan(now: now)
        let usage = try #require(await provider.usage(now: now))
        // The newest token_count wins: 37 % of five hours, 12 % of the week.
        #expect(usage.primary?.usedPercent == 37)
        #expect(usage.primary?.label == "5 h")
        #expect(UTC.seconds(usage.primary?.resetsAt) == 1_792_515_175)
        #expect(usage.secondary?.usedPercent == 12)
        #expect(usage.secondary?.label == "week")
        #expect(usage.plan == "plus")
        // After the reset time the window starts from zero.
        let later = try #require(await provider.usage(now: UTC.date("2026-10-20 17:00")))
        #expect(later.primary?.usedPercent == 0)
        #expect(later.secondary?.usedPercent == 12)
    }

    @Test func usageWithoutRecentSessions() async throws {
        let home = Fixtures.codexHome(now: now)
        defer { Fixtures.remove(home) }
        // No scan yet: the newest thread's rollout still has the last limits.
        let usage = try #require(await CodexProvider(root: home, useProcesses: false).usage(now: now))
        #expect(usage.primary?.usedPercent == 37)
    }

    @Test func olderFormatWithoutDatabase() async throws {
        let home = Fixtures.codexLegacyHome(now: now)
        defer { Fixtures.remove(home) }
        let scan = await CodexProvider(root: home, useProcesses: false).scan(now: now)
        let session = try #require(scan.sessions.first)
        #expect(scan.sessions.count == 1)
        #expect(session.id == "codex:0199a000-0000-7000-8000-00000000eeee")
        #expect(session.title == "Add a dark mode toggle to the settings page")
        #expect(session.project == "lighthouse")
        #expect(session.branch == "feature/export")
        #expect(!session.isBusy)  // interrupted
        #expect(session.steps.map(\.text) == ["rg -n theme src", "Edit settings.ts",
                                              "Added the toggle in src/settings.ts and wired it to the theme store."])
        #expect(session.model == "gpt-5-codex")
        #expect(session.effort == "medium")
        #expect(session.contextTokens == 4150)
        #expect(session.contextWindow == 272_000)
    }

    @Test func olderFormatLimits() throws {
        var rollout = CodexRollout()
        rollout.feed(lines: Substring(Fixtures.text("codex/legacy.jsonl")))
        let limits = try #require(rollout.limits)
        #expect(limits.primary?.usedPercent == 23.5)
        #expect(limits.primary?.label == "5 h")
        #expect(limits.secondary?.label == "week")
        // resets_in_seconds counts from the record's time.
        #expect(UTC.seconds(limits.primary?.resetsAt) == UTC.seconds(UTC.date("2025-09-18 08:00"))! + 12.1 + 7193)
        #expect(rollout.phase == .aborted)
        #expect(!rollout.formatLooksUnknown)
    }

    @Test func unknownFormatSwitchesOff() async {
        let home = Fixtures.codexLegacyHome(now: now, fixture: "codex/unknown.jsonl")
        defer { Fixtures.remove(home) }
        let scan = await CodexProvider(root: home, useProcesses: false).scan(now: now)
        #expect(scan.sessions.isEmpty)
        #expect(scan.unsupported != nil)
    }

    @Test func guardianIsNotASession() {
        var rollout = CodexRollout()
        rollout.feed(lines: Substring(Fixtures.text("codex/guardian.jsonl")))
        #expect(rollout.isGuardian)
        var sub = CodexRollout()
        sub.feed(lines: Substring(Fixtures.text("codex/subagent.jsonl")))
        #expect(sub.parentThreadID == "019a0001-0000-7000-8000-00000000b0d1")
        #expect(sub.nickname == "Lovelace")
        #expect(!sub.isGuardian)
    }
}

@Suite struct ClaudeProviderTests {
    let now = UTC.date("2026-10-20 12:00")

    @Test func desktopAppImprovesTitleAndNeedsAction() async throws {
        let fixture = Fixtures.claudeHome()
        defer { Fixtures.remove(fixture.home.deletingLastPathComponent()) }
        let provider = ClaudeCodeProvider(root: fixture.home, desktop: ClaudeDesktop(root: fixture.desktop))
        let sessions = await provider.scan(now: now).sessions
        let session = try #require(sessions.first)
        #expect(sessions.count == 1)
        #expect(session.id == "5e550000-0000-4000-8000-000000000001")
        #expect(session.provider == "claude-code")
        #expect(session.title == "Report page: faster loading")
        #expect(session.needsYou == "Yes to merge the faster report page")
        #expect(session.project == "harbor")
        #expect(session.model == "claude-opus-5-5")
        #expect(session.effort == "high")
        #expect(session.contextTokens == 43_010)
        #expect(session.steps.last?.text == "The page loads in 120 ms now. Merge it?")
    }

    @Test func withoutTheAppNothingChanges() async throws {
        let fixture = Fixtures.claudeHome()
        defer { Fixtures.remove(fixture.home.deletingLastPathComponent()) }
        let session = try #require(await ClaudeCodeProvider(root: fixture.home, desktop: nil).scan(now: now).sessions.first)
        #expect(session.title == "Speed up the report page")
        #expect(session.needsYou == nil)
    }

    @Test func desktopFileParsing() throws {
        let file = Fixtures.text("claude/desktop/acct-0000/org-0000/local_0000aaaa-0000-4000-8000-000000000001.json")
        let session = try #require(ClaudeDesktop.Session.parse(Bytes.data(file)))
        #expect(session.cliSessionId == "5e550000-0000-4000-8000-000000000001")
        #expect(session.status == "blocked")
        #expect(!session.isArchived)
        // Busy sessions don't show the last turn's "needs action".
        let busy = AgentSession(id: "x", project: "p", cwd: "/", isBusy: true)
        #expect(session.enrich(busy, userNamed: false).needsYou == nil)
        // A name the user gave in the terminal stays.
        let named = AgentSession(id: "x", project: "p", title: "Mine", cwd: "/", isBusy: false)
        #expect(session.enrich(named, userNamed: true).title == "Mine")
        #expect(ClaudeDesktop.Session.parse(Bytes.data("{}")) == nil)
    }

    @Test func sameProjectAcrossTools() async throws {
        let fixture = Fixtures.claudeHome()
        let home = Fixtures.codexHome(now: now)
        defer { Fixtures.remove(fixture.home.deletingLastPathComponent()); Fixtures.remove(home) }
        let claude = try #require(await ClaudeCodeProvider(root: fixture.home, desktop: nil).scan(now: now).sessions.first)
        let codex = try #require(await CodexProvider(root: home, useProcesses: false).scan(now: now).sessions.first)
        // One project, one character, whichever tool works in it.
        #expect(claude.project == codex.project)
        #expect(claude.provider != codex.provider)
    }
}

@Suite struct ProviderProtocolTests {
    @Test func hookBeatsFilesForApprovals() {
        let at = UTC.date("2026-10-20 12:00")
        let session = AgentSession(id: "codex:a", project: "p", cwd: "/", isBusy: true, since: UTC.date("2026-10-20 11:00"))
        let waiting = SessionMerge.apply([AgentEvent(sessionID: "codex:a", kind: .needsApproval("Approve: npm test"), at: at)],
                                         to: [session], fileTimes: ["codex:a": UTC.date("2026-10-20 12:05")])
        #expect(waiting.first?.needsYou == "Approve: npm test")
        #expect(waiting.first?.isBusy == false)
        // A working/idle event older than the files is stale.
        let stale = SessionMerge.apply([AgentEvent(sessionID: "codex:a", kind: .idle, at: at)],
                                       to: [session], fileTimes: ["codex:a": UTC.date("2026-10-20 12:05")])
        #expect(stale.first?.isBusy == true)
        let fresh = SessionMerge.apply([AgentEvent(sessionID: "codex:a", kind: .idle, at: at)],
                                       to: [session], fileTimes: ["codex:a": UTC.date("2026-10-20 11:30")])
        #expect(fresh.first?.isBusy == false)
        // The process list only fills gaps.
        let filled = SessionMerge.fill([session], processes: ["codex:a": (pid: 42, tty: "/dev/ttys004")])
        #expect(filled.first?.pid == 42)
        #expect(filled.first?.tty == "/dev/ttys004")
    }

    @Test func closestToItsLimitFirst() {
        let at = UTC.date("2026-10-20 12:00")
        let claude = AgentUsage(provider: "claude-code", displayName: "Claude", primary: .init(usedPercent: 62, minutes: 300, resetsAt: nil), secondary: nil, capturedAt: at)
        let codex = AgentUsage(provider: "codex", displayName: "Codex", primary: .init(usedPercent: 10, minutes: 300, resetsAt: nil),
                               secondary: .init(usedPercent: 81, minutes: 10_080, resetsAt: nil), capturedAt: at)
        #expect(AgentUsage.ordered([claude, codex]).map(\.provider) == ["codex", "claude-code"])
    }

    @Test func terminalScripts() throws {
        let terminal = try #require(TerminalJump.script(bundleID: TerminalJump.terminal, tty: "/dev/ttys004"))
        #expect(terminal.contains("tty of t is \"/dev/ttys004\""))
        #expect(TerminalJump.script(bundleID: TerminalJump.iTerm, tty: "/dev/ttys004")?.contains("sessions of t") == true)
        // Nothing unexpected goes into a script.
        #expect(TerminalJump.script(bundleID: TerminalJump.terminal, tty: "/dev/ttys004\" & do shell script \"x") == nil)
        #expect(TerminalJump.script(bundleID: "com.example.unknown", tty: "/dev/ttys004") == nil)
        let panes = "/dev/ttys001 main:0.0\n/dev/ttys004 work:2.1\n"
        #expect(TerminalJump.tmuxTarget(panes: panes, tty: "/dev/ttys004") == "work:2.1")
        #expect(TerminalJump.tmuxTarget(panes: panes, tty: "/dev/ttys009") == nil)
        let client = TerminalJump.tmuxClient(clients: "811 /dev/ttys000 main\n922 /dev/ttys002 work\n", session: "work")
        #expect(client?.pid == 922)
        #expect(client?.tty == "/dev/ttys002")
    }
}
