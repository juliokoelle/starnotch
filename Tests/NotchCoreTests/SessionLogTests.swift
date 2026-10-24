import Testing
import TestSupport
@testable import NotchCore

@Suite struct SessionLogTests {
    let tail = """
    ial line cut off mid-record","type":"assistant"}
    {"type":"ai-title","aiTitle":"Generated title","sessionId":"s"}
    {"type":"user","timestamp":"2026-10-20T11:00:00.000Z","cwd":"/Users/j/projects/notch-switcher","gitBranch":"variant-b","message":{"role":"user","content":"Build it"}}
    {"type":"assistant","timestamp":"2026-10-20T11:00:05.000Z","cwd":"/Users/j/projects/notch-switcher","message":{"role":"assistant","content":[{"type":"text","text":"\\nLet me read the code first.\\nMore."},{"type":"tool_use","name":"Read","input":{"file_path":"/Users/j/projects/notch-switcher/README.md"}}]}}
    {"type":"user","timestamp":"2026-10-20T11:00:06.000Z","message":{"role":"user","content":[{"type":"tool_result","content":"..."}]}}
    {"type":"assistant","timestamp":"2026-10-20T11:00:09.000Z","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/x/TaskList.tsx","old_string":"a","new_string":"b"}}]}}
    {"type":"assistant","timestamp":"2026-10-20T11:00:12.000Z","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"swift test","description":"Run unit tests"}}]}}
    {"type":"assistant","timestamp":"2026-10-20T11:00:15.000Z","message":{"role":"assistant","content":[{"type":"tool_use","name":"Agent","input":{"description":"Build own notch","prompt":"..."}}]}}
    {"type":"custom-title","customTitle":"Docs refresh","sessionId":"s"}
    {"type":"system","timestamp":"2026-10-20T11:00:20.000Z"}
    """

    @Test func latestStepsAndMetadata() {
        let activity = SessionLog.activity(fromTail: tail)
        #expect(activity.title == "Docs refresh")
        #expect(activity.cwd == "/Users/j/projects/notch-switcher")
        #expect(activity.branch == "variant-b")
        #expect(activity.steps.map(\.text) == ["Reading README.md", "Editing TaskList.tsx", "Run unit tests", "Subagent: Build own notch"])
        #expect(activity.current?.kind == .agent)
        #expect(activity.firstPrompt == "Build it")
        #expect(activity.effort == nil)
        #expect(activity.lastMessage == "Let me read the code first.")
        #expect(UTC.string(activity.lastDate) == "2026-10-20 11:00")
    }

    @Test func textMessagesBecomeSteps() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":"  \n Done. All tests pass."}]}}"#
        let activity = SessionLog.activity(fromTail: line)
        #expect(activity.steps == [SessionStep(kind: .message, text: "Done. All tests pass.")])
        #expect(activity.title == nil)
    }

    @Test func toolDescriptions() {
        #expect(SessionLog.describe(tool: "Bash", input: ["command": "git status\ngit log"]).1 == "Running git status")
        #expect(SessionLog.describe(tool: "Write", input: ["file_path": "/a/b/Notch.swift"]).1 == "Writing Notch.swift")
        #expect(SessionLog.describe(tool: "Grep", input: ["pattern": "foo"]).1 == "Searching for \u{201C}foo\u{201D}")
        #expect(SessionLog.describe(tool: "WebFetch", input: ["url": "https://example.com/x"]).1 == "Reading example.com")
        #expect(SessionLog.describe(tool: "mcp__claude_ai_Notion__notion-fetch", input: [:]).1 == "Notion: notion-fetch")
        #expect(SessionLog.describe(tool: "SendMessage", input: [:]).1 == "Messaging a subagent")
        #expect(SessionLog.describe(tool: "ToolSearch", input: [:]).1 == "Loading tools")
        #expect(SessionLog.describe(tool: "Unknown", input: [:]) == (.tool, "Unknown"))
    }

    @Test func emptyOrGarbageTail() {
        #expect(SessionLog.activity(fromTail: "") == SessionActivity())
        #expect(SessionLog.activity(fromTail: "not json\n{broken").steps.isEmpty)
    }

    @Test func sessionRecord() throws {
        let json = #"{"pid":3741,"sessionId":"28d5","cwd":"/Users/j/notes","startedAt":1792446689943,"name":"Docs refresh","status":"busy","statusUpdatedAt":1792494268004,"extra":true}"#
        let record = try #require(SessionRecord.decode(Bytes.data(json)))
        #expect(record.isBusy)
        #expect(record.name == "Docs refresh")
        #expect(UTC.seconds(record.statusSince) == 1_792_494_268.004)
        #expect(!record.isBackgroundHelper)
        #expect(SessionRecord.decode(Bytes.data(#"{"pid":1}"#)) == nil)
        let named = try #require(SessionRecord.decode(Bytes.data(#"{"pid":3,"sessionId":"s","cwd":"/x","name":"Notch Tool","nameSource":"user","bridgeSessionId":"session_01AB"}"#)))
        #expect(named.userName == "Notch Tool")
        #expect(named.remoteURL?.absoluteString == "https://claude.ai/code/session_01AB")
        #expect(record.userName == nil)   // no nameSource: a derived name
    }

    @Test func launchctlList() {
        let output = """
        PID\tStatus\tLabel
        -\t0\tcom.example.zz.link-check
        512\t0\tcom.example.tools.meeting-notes
        -\t78\tcom.example.tools.backup
        -\t0\tcom.apple.something
        """
        let jobs = LaunchdJob.parse(output, prefix: "com.example.")
        #expect(jobs.map(\.label) == ["com.example.tools.backup", "com.example.tools.meeting-notes", "com.example.zz.link-check"])
        #expect(jobs[0].lastExitStatus == 78)
        #expect(jobs[1].isRunning)
        #expect(!jobs[2].isRunning)
    }

    @Test func durations() {
        #expect(Durations.short(42) == "42s")
        #expect(Durations.short(12 * 60 + 5) == "12m")
        #expect(Durations.short(2 * 3600 + 5 * 60) == "2h 5m")
        #expect(Durations.short(3 * 3600) == "3h")
        #expect(Durations.short(3 * 86_400 + 5) == "3d")
    }

    @Test func modelAndEffort() {
        let line = #"{"type":"assistant","requestedModel":"claude-opus-5-5","effort":"max","message":{"model":"claude-opus-5-5","content":[{"type":"text","text":"ok"}]}}"#
        let activity = SessionLog.activity(fromTail: line)
        #expect(activity.effort == "max")
        #expect(activity.model == "claude-opus-5-5")
    }
}
