import Testing
import TestSupport
@testable import NotchCore

@Suite struct SubagentLogTests {
    let opening = #"""
    {"type":"user","timestamp":"2026-10-22T10:00:00.000Z","message":{"role":"user","content":"Make the meeting notes land in the vault automatically.\nMore context here."}}
    {"type":"assistant","timestamp":"2026-10-22T10:00:05.000Z","message":{"role":"assistant","stop_reason":"tool_use","usage":{"input_tokens":10,"cache_read_input_tokens":2000,"output_tokens":50},"content":[{"type":"text","text":"Let me look at the exporter."},{"type":"tool_use","name":"Read","input":{"file_path":"/x/export.py"}}]}}
    {"type":"user","timestamp":"2026-10-22T10:00:06.000Z","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}
    {"type":"assistant","timestamp":"2026-10-22T10:00:09.000Z","message":{"role":"assistant","stop_reason":"tool_use","usage":{"input_tokens":12,"cache_read_input_tokens":2600,"output_tokens":40},"content":[{"type":"tool_use","name":"Bash","input":{"command":"swift build","description":"Run the build"}}]}}
    """#

    @Test func taskStepsAndCounts() {
        var progress = SubagentProgress()
        progress.feed(lines: Substring(opening))
        #expect(progress.task == "Make the meeting notes land in the vault automatically.")
        #expect(progress.steps.map(\.text) == ["Let me look at the exporter.", "Reading export.py", "Run the build"])
        #expect(progress.toolUses == 2)
        #expect(progress.outputTokens == 90)
        #expect(progress.contextTokens == 2612)
        #expect(progress.lastText == "Let me look at the exporter.")
        let now = UTC.date("2026-10-22 10:01")
        #expect(progress.status(modified: now, now: now) == .running)
        #expect(progress.status(modified: UTC.date("2026-10-22 09:50"), now: now) == .stopped)
        #expect(progress.report == nil)
    }

    @Test func incrementalFeedMatchesOnePass() {
        var whole = SubagentProgress()
        whole.feed(lines: Substring(opening))
        var pieces = SubagentProgress()
        for line in opening.split(separator: "\n") { pieces.feed(line: line) }
        #expect(whole == pieces)
    }

    @Test func handbackIsTheResult() {
        var progress = SubagentProgress()
        progress.feed(lines: Substring(opening + "\n" + #"""
        {"type":"assistant","timestamp":"2026-10-22T10:02:00.000Z","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","name":"SubagentHandback","input":{"message":"Notes now arrive every 30 minutes.\n\nDetails follow."}}]}}
        {"type":"assistant","timestamp":"2026-10-22T10:02:01.000Z","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"I've sent the report."}]}}
        """#))
        #expect(progress.report == "Notes now arrive every 30 minutes.\n\nDetails follow.")
        #expect(SubagentProgress.excerpt(progress.report!) == "Notes now arrive every 30 minutes.\nDetails follow.")
        let now = UTC.date("2026-10-22 10:03")
        #expect(progress.status(modified: now, now: now) == .done)
    }

    @Test func continuedAfterReportIsRunning() {
        var progress = SubagentProgress()
        progress.feed(lines: Substring(opening + "\n" + #"""
        {"type":"assistant","timestamp":"2026-10-22T10:02:00.000Z","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","name":"SubagentHandback","input":{"message":"First report."}}]}}
        {"type":"user","timestamp":"2026-10-22T10:05:00.000Z","message":{"role":"user","content":"Next task, please."}}
        {"type":"assistant","timestamp":"2026-10-22T10:05:10.000Z","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","name":"Read","input":{"file_path":"/x/next.swift"}}]}}
        """#))
        #expect(progress.report == nil)
        let now = UTC.date("2026-10-22 10:06")
        #expect(progress.status(modified: now, now: now) == .running)
    }

    @Test func closingTextAndErrors() {
        var progress = SubagentProgress()
        progress.feed(lines: Substring(opening + "\n" + #"""
        {"type":"assistant","timestamp":"2026-10-22T10:02:00.000Z","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"All three files are fixed."}]}}
        """#))
        #expect(progress.report == "All three files are fixed.")
        #expect(progress.status(modified: UTC.date("2026-10-22 10:02"), now: UTC.date("2026-10-22 10:02")) == .done)

        var failing = SubagentProgress()
        failing.feed(lines: Substring(opening + "\n" + #"""
        {"type":"assistant","isApiErrorMessage":true,"timestamp":"2026-10-22T10:02:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"API Error: overloaded"}]}}
        """#))
        #expect(failing.status(modified: UTC.date("2026-10-22 10:02"), now: UTC.date("2026-10-22 10:30")) == .failed)
    }

    @Test func meta() {
        let meta = SubagentMeta.decode(Bytes.data(#"{"agentType":"general-purpose","description":"Push reminders","toolUseId":"t"}"#))
        #expect(meta?.description == "Push reminders")
        #expect(meta?.agentType == "general-purpose")
    }
}
