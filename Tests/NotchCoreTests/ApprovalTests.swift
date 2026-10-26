import Testing
import TestSupport
@testable import NotchCore

@Suite(.serialized) struct ApprovalTests {
    let bash = #"{"session_id":"s1","cwd":"/x","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf node_modules","description":"Clean"},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"rm -rf node_modules"}],"behavior":"allow","destination":"localSettings"}]}"#

    @Test func parsesTheHookInput() throws {
        let request = try #require(ApprovalRequest.parse(Bytes.data(bash), id: "r"))
        #expect(request.tool == "Bash")
        #expect(request.summary == "rm -rf node_modules")
        #expect(request.sessionID == "s1")
        #expect(request.allowRules == [["toolName": "Bash", "ruleContent": "rm -rf node_modules"]])
        #expect(ApprovalRequest.parse(Bytes.data(#"{"hook_event_name":"PreToolUse","tool_name":"Bash"}"#)) == nil)
        #expect(ApprovalRequest.parse(Bytes.data("not json")) == nil)
        let edit = ApprovalRequest.parse(Bytes.data(#"{"hook_event_name":"PermissionRequest","tool_name":"Edit","tool_input":{"file_path":"/a/b.swift"}}"#))
        #expect(edit?.summary == "/a/b.swift")
    }

    @Test func decisionsMatchTheDocumentedJSON() throws {
        let request = try #require(ApprovalRequest.parse(Bytes.data(bash), id: "r"))
        #expect(String(decoding: ApprovalDecision.allowOnce.output(for: request), as: UTF8.self)
                == #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#)
        #expect(String(decoding: ApprovalDecision.deny.output(for: request), as: UTF8.self)
                == #"{"hookSpecificOutput":{"decision":{"behavior":"deny","message":"Denied from the notch."},"hookEventName":"PermissionRequest"}}"#)
        let session = String(decoding: ApprovalDecision.allowSession.output(for: request), as: UTF8.self)
        #expect(session.contains(#""destination":"session""#))
        #expect(session.contains(#""type":"addRules""#))
        #expect(session.contains(#""ruleContent":"rm -rf node_modules""#))
        #expect(!session.contains("localSettings"))
        // No suggestion: a Bash command is allowed only as exactly that command.
        var bare = request
        bare.allowRules = []
        #expect(String(decoding: ApprovalDecision.allowSession.output(for: bare), as: UTF8.self)
            .contains(#""ruleContent":"rm -rf node_modules""#))
    }

    @Test func socketRoundTrips() {
        let allow = ApprovalHarness.roundTrip(json: bash, decision: .allowOnce)
        #expect(allow.reply.contains(#""behavior":"allow""#))
        let deny = ApprovalHarness.roundTrip(json: bash, decision: .deny)
        #expect(deny.reply.contains(#""behavior":"deny""#))
        // No decision (timeout in the app): no output, so Claude Code shows its own prompt.
        #expect(ApprovalHarness.roundTrip(json: bash, decision: nil).reply.isEmpty)
        // Not a permission request: closed without a reply.
        #expect(ApprovalHarness.roundTrip(json: #"{"hello":1}"#, decision: .allowOnce).reply.isEmpty)
    }

    @Test func hookGoingAwayCancels() {
        let result = ApprovalHarness.roundTrip(json: bash, decision: .allowOnce, delay: 5, closeEarly: true)
        #expect(result.cancelled)
    }

    @Test func socketIsPrivate() {
        let modes = ApprovalHarness.socketMode()
        #expect(modes.folder == 0o700)
        #expect(modes.socket == 0o600)
    }
}

@Suite struct CodexApprovalTests {
    let request = #"{"starnotch_provider":"codex","session_id":"019a0001","turn_id":"t1","transcript_path":null,"cwd":"/Users/ada/projects/harbor","hook_event_name":"PermissionRequest","model":"gpt-6.1-sol","permission_mode":"default","tool_name":"Bash","tool_input":{"command":"npm test","description":null}}"#

    @Test func parsesCodexRequests() throws {
        let parsed = try #require(ApprovalRequest.parse(Bytes.data(request), id: "r"))
        #expect(parsed.provider == "codex")
        #expect(parsed.agentID == "codex:019a0001")
        #expect(parsed.summary == "npm test")
        #expect(!parsed.supportsSessionRules)
        // Claude Code's requests keep their bare id.
        let claude = try #require(ApprovalRequest.parse(Bytes.data(#"{"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"}}"#)))
        #expect(claude.provider == "claude-code")
        #expect(claude.agentID == "s")
        #expect(claude.supportsSessionRules)
    }

    @Test func codexRepliesAllowOrDenyOnly() throws {
        let parsed = try #require(ApprovalRequest.parse(Bytes.data(request), id: "r"))
        let allow = #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#
        #expect(String(decoding: ApprovalDecision.allowOnce.output(for: parsed), as: UTF8.self) == allow)
        // No updatedPermissions: Codex fails closed on them.
        #expect(String(decoding: ApprovalDecision.allowSession.output(for: parsed), as: UTF8.self) == allow)
        #expect(String(decoding: ApprovalDecision.deny.output(for: parsed), as: UTF8.self)
                == #"{"hookSpecificOutput":{"decision":{"behavior":"deny","message":"Denied from the notch."},"hookEventName":"PermissionRequest"}}"#)
    }

    @Test func patchSummaryNamesTheFiles() throws {
        let patch = #"{"starnotch_provider":"codex","session_id":"s","hook_event_name":"PermissionRequest","tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** Update File: Sources/Report.swift\n@@\n-a\n+b\n*** Add File: Tests/ReportTests.swift\n+x\n*** End Patch"}}"#
        let parsed = try #require(ApprovalRequest.parse(Bytes.data(patch)))
        #expect(parsed.summary == "Edit Report.swift, ReportTests.swift")
        #expect(parsed.detail.hasPrefix("*** Begin Patch"))
    }

    @Test func codexProviderUsesTheSameReply() {
        let provider = CodexProvider(root: Fixtures.codexLegacyHome(now: UTC.date("2026-10-20 12:00")), useProcesses: false)
        let parsed = ApprovalRequest.parse(Bytes.data(request), id: "r")!
        #expect(provider.reply(to: parsed, with: .deny) == ApprovalDecision.deny.output(for: parsed))
        #expect(provider.parse(hook: Bytes.data(request))?.sessionID == "codex:019a0001")
        #expect(provider.approvalSetup.install.hasSuffix("codex/install-hook.sh\""))
    }

    @Test func mcpQuestionsCarryOptionsAndAnswers() throws {
        let json = #"{"hook_event_name":"PermissionRequest","starnotch_provider":"mcp","tool_name":"Cursor","tool_input":{"description":"Deploy where?"},"starnotch_options":["Staging"," ","Production","a","b"],"starnotch_free_text":true}"#
        let request = try #require(ApprovalRequest.parse(Data(json.utf8)))
        #expect(request.options == ["Staging", "Production", "a", "b"])
        #expect(request.freeText && request.asksForAnswer)
        let answer = String(decoding: ApprovalDecision.answer("Staging").output(for: request), as: UTF8.self)
        #expect(answer.contains(#""starnotch_answer":"Staging""#) && answer.contains(#""behavior":"allow""#))
        #expect(String(decoding: ApprovalDecision.deny.output(for: request), as: UTF8.self).contains(#""behavior":"deny""#))
        // Options only count for the MCP server's questions.
        let claude = #"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"},"starnotch_options":["x"]}"#
        #expect(try #require(ApprovalRequest.parse(Data(claude.utf8))).options.isEmpty)
    }
}
