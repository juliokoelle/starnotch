import Foundation
import Testing
import TestSupport
@testable import NotchCore

/// Cursor, Copilot CLI, Gemini CLI and opencode: their hooks in one shape, their files as golden
/// tests (anonymised, Tests/Fixtures), the approvals in each tool's words.
@Suite struct HookUpdateTests {
    let now = UTC.date("2026-10-20 12:00")

    @Test func cursorShellCallBecomesAStepWithItsProcess() throws {
        let json = HookJSON.forwarded("hooks/cursor-before-shell.json", provider: "cursor", event: "afterShellExecution")
        let update = try #require(HookJSON.update(json, at: now))
        #expect(update.provider == "cursor")
        #expect(update.sessionID == "c0ffee00-0000-4000-8000-000000000001")
        #expect(update.agentID == "cursor:c0ffee00-0000-4000-8000-000000000001")
        #expect(update.cwd == "/Users/me/projects/harbor")
        #expect(update.pid == 4242)
        #expect(update.tty == "/dev/ttys007")
        #expect(update.kind == .tool(SessionStep(kind: .shell, text: "npm run migrate -- --env staging")))
        #expect(update.model == "composer-2")
    }

    @Test func eachToolsEventsMapToTheSameWords() throws {
        func kind(_ json: String) -> HookUpdate.Kind? { HookJSON.update(json, at: now)?.kind }
        #expect(kind(#"{"starnotch_provider":"cursor","hook_event_name":"beforeSubmitPrompt","conversation_id":"c1","prompt":"Fix the flaky test\nplease"}"#)
                == .prompt("Fix the flaky test"))
        #expect(kind(#"{"starnotch_provider":"cursor","hook_event_name":"stop","conversation_id":"c1","status":"completed"}"#) == .idle(nil))
        #expect(kind(#"{"starnotch_provider":"cursor","hook_event_name":"afterFileEdit","conversation_id":"c1","file_path":"/p/src/App.swift"}"#)
                == .tool(SessionStep(kind: .edit, text: "Editing App.swift")))
        // Copilot names the event in the script's argument; its tool arguments are a JSON string.
        #expect(kind(#"{"starnotch_provider":"copilot","starnotch_event":"preToolUse","sessionId":"s1","toolName":"bash","toolArgs":"{\"command\":\"npm test\"}"}"#)
                == .tool(SessionStep(kind: .shell, text: "npm test")))
        #expect(kind(#"{"starnotch_provider":"copilot","starnotch_event":"agentStop","sessionId":"s1"}"#) == .idle(nil))
        #expect(kind(#"{"starnotch_provider":"copilot","starnotch_event":"sessionEnd","sessionId":"s1","reason":"exit"}"#) == .ended)
        #expect(kind(#"{"starnotch_provider":"gemini","hook_event_name":"BeforeAgent","session_id":"g1","prompt":"Why is it slow?"}"#)
                == .prompt("Why is it slow?"))
        #expect(kind(#"{"starnotch_provider":"gemini","hook_event_name":"BeforeTool","session_id":"g1","tool_name":"read_file","tool_input":{"absolute_path":"/p/a.swift"}}"#)
                == .tool(SessionStep(kind: .read, text: "Reading a.swift")))
        #expect(kind(#"{"starnotch_provider":"opencode","hook_event_name":"session.status","session_id":"o1","status":"busy"}"#) == .prompt(nil))
        #expect(kind(#"{"starnotch_provider":"opencode","hook_event_name":"session.updated","session_id":"o1","title":"Speed up the report"}"#)
                == .title("Speed up the report"))
        // Not ours, or nothing to say.
        #expect(kind(#"{"starnotch_provider":"cursor","hook_event_name":"beforeReadFile","conversation_id":"c1"}"#) == nil)
        #expect(kind(#"{"hook_event_name":"Stop","session_id":"x"}"#) == nil)
        #expect(kind(#"{"starnotch_provider":"other","hook_event_name":"stop","session_id":"x"}"#) == nil)
    }

    @Test func geminiPermissionPromptShowsAsWaiting() throws {
        let json = HookJSON.forwarded("hooks/gemini-notification.json", provider: "gemini", event: "Notification")
        let update = try #require(HookJSON.update(json, at: now))
        #expect(update.kind == .waiting("Allow shell command: rm -rf build?"))
        #expect(update.agentID == "gemini:ab12cd34-0000-4000-8000-0000000000ge")
    }

    @Test func copilotWithoutSessionIdsUsesTheProcess() throws {
        // An older Copilot CLI: no session id, the tool's arguments as JSON text.
        let json = #"{"starnotch_provider":"copilot","starnotch_event":"postToolUse","starnotch_pid":4242,"cwd":"/p","toolName":"bash","toolArgs":"{\"command\":\"git push --force-with-lease\"}"}"#
        let update = try #require(HookJSON.update(json, at: now))
        #expect(update.sessionID == "pid-4242")
        #expect(update.kind == .tool(SessionStep(kind: .shell, text: "git push --force-with-lease")))
    }

    @Test func copilotsOwnPromptShowsAsWaiting() throws {
        // As Copilot CLI 1.0 sends it, when its permission flow asks in the terminal.
        let json = #"{"starnotch_provider":"copilot","starnotch_event":"notification","starnotch_pid":4242,"sessionId":"s1","cwd":"/p","message":"Path permission needed: /p/out","title":"Permission needed","hook_event_name":"Notification","notification_type":"permission_prompt"}"#
        let update = try #require(HookJSON.update(json, at: now))
        #expect(update.kind == .waiting("Path permission needed: /p/out"))
        #expect(HookJSON.update(json.replacingOccurrences(of: "permission_prompt", with: "agent_idle"), at: now) == nil)
    }

    @Test func unsafeTerminalsAreDropped() throws {
        let json = #"{"starnotch_provider":"cursor","hook_event_name":"stop","conversation_id":"c1","starnotch_tty":"/dev/ttys1\" & x","starnotch_pid":1}"#
        let update = try #require(HookJSON.update(json, at: now))
        #expect(update.tty == nil)
        #expect(update.pid == nil)
    }
}

@Suite struct HookSessionsTests {
    let start = UTC.date("2026-10-20 12:00")

    func update(_ kind: HookUpdate.Kind, _ minute: String, id: String = "c1", pid: Int32? = nil, tty: String? = nil,
                parent: String? = nil) -> HookUpdate {
        HookUpdate(provider: "cursor", sessionID: id, kind: kind, at: UTC.date("2026-10-20 \(minute)"),
                   cwd: "/Users/me/projects/harbor", pid: pid, tty: tty, parentID: parent)
    }

    @Test func aTurnWorksThenRestsWithItsSteps() {
        var store = HookSessions()
        store.apply(update(.prompt("Fix the flaky test"), "12:00"))
        store.apply(update(.tool(SessionStep(kind: .shell, text: "npm test")), "12:02"))
        var sessions = store.sessions(provider: "cursor", now: UTC.date("2026-10-20 12:03"), isAlive: { _ in true })
        #expect(sessions.count == 1)
        #expect(sessions[0].id == "cursor:c1")
        #expect(sessions[0].isBusy)
        #expect(sessions[0].title == "Fix the flaky test")
        #expect(sessions[0].project == "harbor")
        #expect(UTC.string(sessions[0].since) == "2026-10-20 12:00")
        #expect(sessions[0].steps.map(\.text) == ["npm test"])
        store.apply(update(.idle("All green."), "12:05"))
        sessions = store.sessions(provider: "cursor", now: UTC.date("2026-10-20 12:06"), isAlive: { _ in true })
        #expect(!sessions[0].isBusy)
        #expect(sessions[0].lastMessage == "All green.")
        #expect(UTC.string(sessions[0].since) == "2026-10-20 12:05")
        // Other tools' sessions aren't listed.
        #expect(store.sessions(provider: "gemini", now: UTC.date("2026-10-20 12:06"), isAlive: { _ in true }).isEmpty)
    }

    @Test func waitingHoldsUntilAnswered() {
        var store = HookSessions()
        store.apply(update(.prompt(nil), "12:00"))
        store.apply(update(.waiting("Allow rm -rf build?"), "12:01"))
        var session = store.sessions(provider: "cursor", now: UTC.date("2026-10-20 12:02"), isAlive: { _ in true })[0]
        #expect(session.needsYou == "Allow rm -rf build?")
        #expect(!session.isBusy)
        store.apply(update(.answered, "12:03"))
        session = store.sessions(provider: "cursor", now: UTC.date("2026-10-20 12:03"), isAlive: { _ in true })[0]
        #expect(session.needsYou == nil)
        #expect(session.isBusy)
    }

    @Test func sessionsEndStaleAndGo() {
        var store = HookSessions()
        store.apply(update(.prompt(nil), "12:00"))
        // Busy without a word for over 15 minutes: resting, since its last word.
        var session = store.sessions(provider: "cursor", now: UTC.date("2026-10-20 12:20"), isAlive: { _ in true })[0]
        #expect(!session.isBusy)
        #expect(UTC.string(session.since) == "2026-10-20 12:00")
        // Without a process, gone after the recent window.
        #expect(store.sessions(provider: "cursor", now: UTC.date("2026-10-20 12:50"), isAlive: { _ in true }).isEmpty)
        // A dead process ends it at once; an end event too.
        store.apply(update(.prompt(nil), "13:00", id: "c2", pid: 77))
        #expect(store.sessions(provider: "cursor", now: UTC.date("2026-10-20 13:01"), isAlive: { _ in false }).isEmpty)
        store.apply(update(.prompt(nil), "13:00", id: "c3"))
        store.apply(update(.ended, "13:01", id: "c3"))
        #expect(store.entries.isEmpty)
        // A live process in a terminal keeps a resting session for hours.
        store.apply(update(.idle(nil), "13:00", id: "c4", pid: 78, tty: "/dev/ttys004"))
        session = store.sessions(provider: "cursor", now: UTC.date("2026-10-20 16:00"), isAlive: { _ in true })[0]
        #expect(session.pid == 78)
    }

    @Test func aProcessThatHostsManySessionsDoesNotKeepThemAll() {
        var store = HookSessions()
        // Cursor's editor: one process without a terminal for every conversation.
        store.apply(update(.idle(nil), "12:00", id: "a", pid: 90))
        store.apply(update(.idle(nil), "12:00", id: "b", pid: 90))
        // One CLI in a terminal with two sessions (one opencode).
        store.apply(update(.idle(nil), "12:00", id: "c", pid: 91, tty: "/dev/ttys005"))
        store.apply(update(.idle(nil), "12:00", id: "d", pid: 91, tty: "/dev/ttys005"))
        // A CLI of its own keeps its one session.
        store.apply(update(.idle(nil), "12:00", id: "e", pid: 92, tty: "/dev/ttys006"))
        #expect(store.sessions(provider: "cursor", now: UTC.date("2026-10-20 12:20"), isAlive: { _ in true }).count == 5)
        let later = store.sessions(provider: "cursor", now: UTC.date("2026-10-20 12:40"), isAlive: { _ in true })
        #expect(later.map(\.id) == ["cursor:e"])
    }

    @Test func atMostSixPerToolAndTheWaitingOnesStay() {
        var store = HookSessions()
        store.apply(update(.waiting("Allow npm publish?"), "12:00", id: "old"))
        for minute in 1...8 { store.apply(update(.idle(nil), "12:0\(minute)", id: "s\(minute)")) }
        let sessions = store.sessions(provider: "cursor", now: UTC.date("2026-10-20 12:10"), isAlive: { _ in true })
        #expect(sessions.count == HookSessions.maxSessions)
        #expect(sessions.contains { $0.id == "cursor:old" })
        #expect(sessions.contains { $0.id == "cursor:s8" })
        #expect(!sessions.contains { $0.id == "cursor:s1" })
    }

    @Test func childSessionsNestAsSubagents() {
        var store = HookSessions()
        store.apply(update(.prompt("Speed up the report"), "12:00", id: "parent"))
        store.apply(update(.title("Find slow queries"), "12:01", id: "child", parent: "parent"))
        store.apply(update(.tool(SessionStep(kind: .search, text: "SELECT")), "12:02", id: "child", parent: "parent"))
        let sessions = store.sessions(provider: "cursor", now: UTC.date("2026-10-20 12:03"), isAlive: { _ in true })
        #expect(sessions.map(\.id) == ["cursor:parent"])
        #expect(sessions[0].subagents.map(\.name) == ["Find slow queries"])
        #expect(sessions[0].subagents[0].status == .running)
    }

    @Test func hooksStateOverTheFilesDetails() {
        let file = AgentSession(id: "gemini:g1", project: "harbor", title: "Report page speed", cwd: "/p/harbor", isBusy: false,
                                since: UTC.date("2026-10-20 11:52"), model: "gemini-3-pro", provider: "gemini")
        let hook = AgentSession(id: "gemini:g1", project: "harbor", title: "Then do it", cwd: "/p/harbor", pid: 9, isBusy: true,
                                since: UTC.date("2026-10-20 11:59"), provider: "gemini", tty: "/dev/ttys002")
        let only = AgentSession(id: "gemini:g2", project: "api", cwd: "/p/api", isBusy: false, provider: "gemini")
        let merged = HookOverlay.merge(files: [file], hooks: [hook, only])
        #expect(merged.map(\.id) == ["gemini:g1", "gemini:g2"])
        #expect(merged[0].isBusy)
        #expect(merged[0].title == "Report page speed")
        #expect(merged[0].model == "gemini-3-pro")
        #expect(merged[0].pid == 9)
        #expect(merged[0].tty == "/dev/ttys002")
    }
}

@Suite struct MoreProviderFileTests {
    let now = UTC.date("2026-10-20 12:00")

    @Test func copilotSessionFolders() async throws {
        let home = Fixtures.copilotHome(now: now)
        defer { Fixtures.remove(home) }
        let provider = CopilotProvider(root: home, useProcesses: false)
        let sessions = await provider.scan(now: now).sessions
        #expect(sessions.map(\.id) == ["copilot:5a1f0c2e-0000-4000-8000-00000000c011", "copilot:5a1f0c2e-0000-4000-8000-00000000c012"])
        let working = sessions[0]
        #expect(working.isBusy)
        #expect(working.title == "Flaky export test")
        #expect(working.project == "harbor")
        #expect(working.branch == "fix/export-test")
        #expect(working.model == "gpt-6.1")
        #expect(working.steps.last?.text == "swift test --filter Export")
        #expect(UTC.string(working.since) == "2026-10-20 11:50")
        let done = sessions[1]
        #expect(!done.isBusy)
        #expect(done.title == "Add pagination to /tasks")
        #expect(done.lastMessage == "Pagination is in; 14 tests pass.")
        #expect(done.steps.last?.text == "Editing tasks.ts")
    }

    @Test func geminiChatRecording() async throws {
        let home = Fixtures.geminiHome(now: now)
        defer { Fixtures.remove(home) }
        let sessions = await GeminiProvider(root: home, useProcesses: false).scan(now: now).sessions
        let session = try #require(sessions.first)
        #expect(session.id == "gemini:ab12cd34-0000-4000-8000-0000000000ge")
        #expect(session.title == "Report page speed")
        #expect(session.project == "harbor")
        #expect(session.isBusy)  // the last record is a prompt, 30 s old
        #expect(session.model == "gemini-3-pro")
        #expect(session.contextTokens == 23_800)
        #expect(session.steps.map(\.text) == ["Reading ReportView.swift"])
        #expect(session.lastMessage == "The page sorts all rows on every render. Memoising the sort fixes it.")
        // A prompt without an answer for minutes is over.
        let old = Fixtures.geminiHome(now: now, age: 600)
        defer { Fixtures.remove(old) }
        #expect(await GeminiProvider(root: old, useProcesses: false).scan(now: now).sessions.first?.isBusy == false)
    }

    @Test func opencodeSessionTable() async throws {
        let folder = Fixtures.opencodeFolder(now: now)
        defer { Fixtures.remove(folder) }
        let provider = OpencodeProvider(folder: folder, useProcesses: false)
        let sessions = await provider.scan(now: now).sessions
        // Yesterday's and the archived one stay out; the subagent nests.
        #expect(sessions.map(\.id) == ["opencode:ses_0001"])
        #expect(sessions[0].title == "Speed up the report page")
        #expect(sessions[0].subagents.map(\.name) == ["Find slow queries (@explore subagent)"])
        // The plugin says it works.
        let busy = HookUpdate(provider: "opencode", sessionID: "ses_0001", kind: .prompt(nil), at: now, cwd: "/Users/me/projects/harbor")
        await provider.ingest(busy)
        let live = await provider.scan(now: now).sessions
        #expect(live.first?.isBusy == true)
        #expect(live.first?.title == "Speed up the report page")
    }
}

@Suite struct MoreApprovalTests {
    @Test func cursorShellPromptAndItsReply() throws {
        let json = HookJSON.forwarded("hooks/cursor-before-shell.json", provider: "cursor", event: "beforeShellExecution")
        let request = try #require(HookJSON.approval(json))
        #expect(request.provider == "cursor")
        #expect(request.tool == "Bash")
        #expect(request.summary == "npm run migrate -- --env staging")
        #expect(request.agentID == "cursor:c0ffee00-0000-4000-8000-000000000001")
        #expect(request.pid == 4242)
        #expect(request.tty == "/dev/ttys007")
        #expect(request.supportsSessionRules)  // kept by the notch (SessionAllowances)
        #expect(request.timeout == 30)
        #expect(HookJSON.text(ApprovalDecision.allowOnce.output(for: request)) == #"{"permission":"allow"}"#)
        #expect(HookJSON.text(ApprovalDecision.deny.output(for: request)).contains(#""permission":"deny""#))
    }

    @Test func copilotPromptAndItsReply() throws {
        let json = HookJSON.forwarded("hooks/copilot-permission.json", provider: "copilot", event: "permissionRequest")
        let request = try #require(HookJSON.approval(json))
        #expect(request.tool == "Bash")
        #expect(request.summary == "git push --force-with-lease")
        #expect(request.agentID == "copilot:5527d0cd-0000-4000-8000-000000000001")
        #expect(request.timeout == 30)
        // permissionRequest takes `behavior` (preToolUse's `permissionDecision` is ignored there).
        #expect(HookJSON.text(ApprovalDecision.allowOnce.output(for: request)) == #"{"behavior":"allow"}"#)
        #expect(HookJSON.text(ApprovalDecision.allowSession.output(for: request)) == #"{"behavior":"allow"}"#)
        #expect(HookJSON.text(ApprovalDecision.deny.output(for: request)) == #"{"behavior":"deny","message":"Denied from the notch."}"#)
    }

    @Test func allowForSessionIsKeptByTheNotchForCursorAndCopilot() throws {
        let json = HookJSON.forwarded("hooks/cursor-before-shell.json", provider: "cursor", event: "beforeShellExecution")
        let request = try #require(HookJSON.approval(json))
        var allowances = SessionAllowances()
        #expect(!allowances.covers(request))
        allowances.allow(request)
        #expect(allowances.covers(request))
        // Another command, or the same one in another session, still asks.
        var other = request
        other.detail = "rm -rf build"
        #expect(!allowances.covers(other))
        var elsewhere = request
        elsewhere.sessionID = "another"
        #expect(!allowances.covers(elsewhere))
        // Tools that keep their own rules aren't remembered here.
        var claude = request
        claude.provider = "claude-code"
        allowances.allow(claude)
        #expect(!allowances.covers(claude))
    }

    @Test func opencodePromptAndItsReply() throws {
        let request = try #require(HookJSON.approval(Fixtures.text("hooks/opencode-permission.json")))
        #expect(request.tool == "Bash")
        #expect(request.summary == "npm run build")
        #expect(request.agentID == "opencode:ses_0001")
        #expect(request.supportsSessionRules)
        #expect(HookJSON.text(ApprovalDecision.allowOnce.output(for: request)) == #"{"reply":"once"}"#)
        #expect(HookJSON.text(ApprovalDecision.allowSession.output(for: request)) == #"{"reply":"always"}"#)
        #expect(HookJSON.text(ApprovalDecision.deny.output(for: request)) == #"{"reply":"reject"}"#)
    }

    @Test func statusEventsAreNotPrompts() {
        let json = HookJSON.forwarded("hooks/cursor-before-shell.json", provider: "cursor", event: "afterShellExecution")
        #expect(HookJSON.approval(json) == nil)
        #expect(HookJSON.approval(HookJSON.forwarded("hooks/gemini-notification.json", provider: "gemini", event: "Notification")) == nil)
    }
}

@Suite struct MoreSetupTests {
    @Test func cursorHooksGoInBesideTheUsersOwnAndComeOutExactly() throws {
        let paths = SetupSandbox.makeWithMoreAgents()
        defer { SetupSandbox.remove(paths.home) }
        let entry = try SetupActions.installCursorHooks(paths)
        let file = paths.cursorHome.appending(path: "hooks.json")
        let hooks = try #require(SetupSandbox.json(file)["hooks"] as? [String: Any])
        let stop = try #require(hooks["stop"] as? [[String: Any]])
        #expect(stop.count == 2)
        #expect((stop[0]["command"] as? String) == "./hooks/my-audit.sh")
        // Status only: nothing that runs before a command, and sessions start and end.
        #expect(hooks["beforeShellExecution"] == nil && hooks["beforeMCPExecution"] == nil)
        #expect(hooks["sessionStart"] != nil && hooks["sessionEnd"] != nil)
        #expect(!SetupSandbox.read(file).contains("--ask"))
        #expect(SetupSandbox.exists(paths.cursorHome.appending(path: "hooks/starnotch-hook.sh").path))
        #expect(SetupSandbox.exists(entry.backup))
        // Twice: still one of ours per event.
        _ = try SetupActions.installCursorHooks(paths)
        #expect(((SetupSandbox.json(file)["hooks"] as? [String: Any])?["stop"] as? [[String: Any]])?.count == 2)
        // Answering is its own choice, with a timeout past the island's wait.
        let approvals = try SetupActions.installCursorApprovals(paths)
        let gate = try #require(((SetupSandbox.json(file)["hooks"] as? [String: Any])?["beforeShellExecution"] as? [[String: Any]])?.first)
        #expect((gate["command"] as? String)?.hasSuffix("cursor beforeShellExecution --ask") == true)
        #expect(gate["timeout"] as? Int == 45)
        // Removing the status leaves the answering hooks and their script.
        try SetupActions.removeCursorHooks(paths, entry: entry)
        #expect((SetupSandbox.json(file)["hooks"] as? [String: Any])?.keys.sorted() == ["beforeMCPExecution", "beforeShellExecution", "stop"])
        #expect(SetupSandbox.exists(paths.cursorHome.appending(path: "hooks/starnotch-hook.sh").path))
        try SetupActions.removeCursorApprovals(paths, entry: approvals)
        let after = SetupSandbox.json(file)
        #expect((after["hooks"] as? [String: Any])?.keys.sorted() == ["stop"])
        #expect(!SetupSandbox.read(file).contains("starnotch-hook.sh"))
        #expect(!SetupSandbox.exists(paths.cursorHome.appending(path: "hooks/starnotch-hook.sh").path))
    }

    @Test func anUpdateRefreshesTheCopiesThatAreSetUp() throws {
        let paths = SetupSandbox.makeWithMoreAgents()
        defer { SetupSandbox.remove(paths.home) }
        var ledger = SetupLedger()
        ledger.record(try SetupActions.installCursorHooks(paths))
        let copy = paths.cursorHome.appending(path: "hooks/starnotch-hook.sh")
        SetupSandbox.write("#!/bin/bash\n# an older version\n", to: copy)
        let refreshed = SetupActions.refreshInstalledCopies(paths, ledger: ledger)
        #expect(refreshed == [copy])
        #expect(SetupSandbox.read(copy) == SetupSandbox.read(try #require(paths.hookScriptSource)))
        // Nothing to do the second time; a tool that isn't set up gets nothing.
        #expect(SetupActions.refreshInstalledCopies(paths, ledger: ledger).isEmpty)
        #expect(!SetupSandbox.exists(paths.geminiHome.appending(path: "hooks/starnotch-hook.sh").path))
    }

    @Test func cursorHooksFileWeCreatedGoesAway() throws {
        let paths = SetupSandbox.makeWithMoreAgents()
        defer { SetupSandbox.remove(paths.home) }
        let file = paths.cursorHome.appending(path: "hooks.json")
        SetupSandbox.remove(file)
        let entry = try SetupActions.installCursorHooks(paths)
        #expect(entry.previous == "created")
        try SetupActions.removeCursorHooks(paths, entry: entry)
        #expect(!SetupSandbox.exists(file.path))
    }

    @Test func geminiHooksKeepTheUsersSettings() throws {
        let paths = SetupSandbox.makeWithMoreAgents()
        defer { SetupSandbox.remove(paths.home) }
        let entry = try SetupActions.installGeminiHooks(paths)
        let file = paths.geminiHome.appending(path: "settings.json")
        let settings = SetupSandbox.json(file)
        #expect(settings["theme"] as? String == "GitHub")
        let before = try #require((settings["hooks"] as? [String: Any])?["BeforeTool"] as? [[String: Any]])
        #expect(before.count == 2)
        #expect(SetupSandbox.read(file).contains("gemini BeforeTool"))
        try SetupActions.removeGeminiHooks(paths, entry: entry)
        let after = SetupSandbox.json(file)
        #expect(after["theme"] as? String == "GitHub")
        #expect(((after["hooks"] as? [String: Any])?["BeforeTool"] as? [[String: Any]])?.count == 1)
        #expect(!SetupSandbox.read(file).contains("starnotch"))
    }

    @Test func copilotAndOpencodeGetFilesOfTheirOwn() throws {
        let paths = SetupSandbox.makeWithMoreAgents()
        defer { SetupSandbox.remove(paths.home) }
        _ = try SetupActions.installCopilotHooks(paths)
        let copilot = SetupActions.copilotHooksFile(paths)
        // Status only; Copilot's own prompt shows as waiting.
        #expect(!SetupSandbox.read(copilot).contains("--ask"))
        #expect(SetupSandbox.read(copilot).contains(#""matcher" : "permission_prompt""#))
        _ = try SetupActions.installCopilotApprovals(paths)
        let approvals = SetupActions.copilotApprovalsFile(paths)
        #expect(SetupSandbox.read(approvals).contains("copilot permissionRequest --ask"))
        try SetupActions.removeCopilotHooks(paths)
        #expect(!SetupSandbox.exists(copilot.path))
        #expect(SetupSandbox.exists(paths.copilotHome.appending(path: "hooks/starnotch-hook.sh").path))
        try SetupActions.removeCopilotApprovals(paths)
        #expect(!SetupSandbox.exists(approvals.path))
        #expect(!SetupSandbox.exists(paths.copilotHome.appending(path: "hooks/starnotch-hook.sh").path))
        _ = try SetupActions.installOpencodePlugin(paths)
        let plugin = SetupActions.opencodePluginFile(paths)
        #expect(SetupSandbox.read(plugin).contains("permission.asked"))
        try SetupActions.removeOpencodePlugin(paths)
        #expect(!SetupSandbox.exists(plugin.path))
    }

    @Test func aBrokenSettingsFileStopsTheChange() throws {
        let paths = SetupSandbox.makeWithMoreAgents()
        defer { SetupSandbox.remove(paths.home) }
        let file = paths.geminiHome.appending(path: "settings.json")
        SetupSandbox.write("{ // not json", to: file)
        #expect(throws: SetupError.self) { try SetupActions.installGeminiHooks(paths) }
        #expect(SetupSandbox.read(file) == "{ // not json")
    }
}
