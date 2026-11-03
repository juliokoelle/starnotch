import Foundation
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

    @Test func returnInTheInboxNeverAllowsWhileANoteOrAnAnswerIsUnderWay() throws {
        var request = try #require(ApprovalRequest.parse(Bytes.data(bash), id: "r"))
        #expect(request.takesNote)
        #expect(request.inboxReturn(noting: false) == .primary)
        // "Instead…" open: ↵ sends the deny with the note, not Allow.
        #expect(request.inboxReturn(noting: true) == .sendNote)
        var question = request
        question.questions = [.init(text: "Which one?", options: [.init(label: "A"), .init(label: "B")])]
        #expect(question.inboxReturn(noting: false) == .nextQuestion)
        request.provider = ApprovalRequest.mcpProvider
        request.freeText = true
        #expect(request.inboxReturn(noting: false) == .field)
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

/// Claude Code's questions with options (`AskUserQuestion`), asked through `PreToolUse` and
/// answered with the picks, and deny with a note.
@Suite struct AgentQuestionTests {
    let ask = #"{"session_id":"s1","cwd":"/x","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which framework?","header":"Framework","options":[{"label":"React","description":"Component library"},{"label":"Vue","description":"Progressive framework"}],"multiSelect":false},{"question":"Which extras?","header":"Extras","options":[{"label":"Tests"},{"label":"Docs"},{"label":"CI"}],"multiSelect":true}]}}"#

    @Test func parsesTheQuestions() throws {
        let request = try #require(ApprovalRequest.parse(Bytes.data(ask), id: "q"))
        #expect(request.hookEvent == "PreToolUse")
        #expect(request.questions.count == 2)
        #expect(request.questions[0].header == "Framework")
        #expect(request.questions[0].options.map(\.label) == ["React", "Vue"])
        #expect(request.questions[0].options[0].detail == "Component library")
        #expect(request.questions[1].multiSelect)
        #expect(request.summary == "Which framework?")
        #expect(request.isQuestion && request.asksForAnswer)
        // A question is never allowed "for the session", and has no deny note.
        #expect(!request.supportsSessionRules)
        #expect(!request.takesNote)
        // Another tool's PreToolUse, or a question without questions, is no card.
        #expect(ApprovalRequest.parse(Bytes.data(#"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}"#)) == nil)
        #expect(ApprovalRequest.parse(Bytes.data(#"{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[]}}"#)) == nil)
    }

    @Test func answersJoinPicksAndTypedText() throws {
        let request = try #require(ApprovalRequest.parse(Bytes.data(ask), id: "q"))
        #expect(request.answers(picks: [0: [1], 1: [2, 0]], typed: [:]) == ["Which framework?": "Vue", "Which extras?": "Tests, CI"])
        // Typed text replaces a single pick and joins several.
        #expect(request.answers(picks: [0: [0], 1: [1]], typed: [0: " Svelte ", 1: "Lint"]) == ["Which framework?": "Svelte", "Which extras?": "Docs, Lint"])
        #expect(request.answers(picks: [:], typed: [1: "  "]).isEmpty)
    }

    @Test func preToolUseReplyEchoesTheQuestionsWithAnswers() throws {
        let request = try #require(ApprovalRequest.parse(Bytes.data(ask), id: "q"))
        let data = ApprovalDecision.answers(["Which framework?": "React", "Which extras?": "Tests, Docs"]).output(for: request)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasPrefix(#"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"#))
        #expect(text.hasSuffix("}}}"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let output = try #require(object["hookSpecificOutput"] as? [String: Any])
        let input = try #require(output["updatedInput"] as? [String: Any])
        #expect((input["answers"] as? [String: String]) == ["Which framework?": "React", "Which extras?": "Tests, Docs"])
        let questions = try #require(input["questions"] as? [[String: Any]])
        #expect(questions.count == 2)
        #expect(questions[0]["header"] as? String == "Framework")
        // Deny: Claude hears there was no answer. Anything else: no reply, the terminal asks.
        #expect(String(decoding: ApprovalDecision.deny.output(for: request), as: UTF8.self)
                == #"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"The user didn't answer from the notch."}}"#)
        #expect(ApprovalDecision.allowOnce.output(for: request).isEmpty)
        // Answers to questions it didn't ask, or none: no reply.
        #expect(ApprovalDecision.answers(["Other?": "x"]).output(for: request).isEmpty)
    }

    @Test func aQuestionAsPermissionPromptIsAllowedWithItsAnswers() throws {
        let permission = ask.replacingOccurrences(of: "PreToolUse", with: "PermissionRequest")
        let request = try #require(ApprovalRequest.parse(Bytes.data(permission), id: "q"))
        let text = String(decoding: ApprovalDecision.answers(["Which framework?": "Vue"]).output(for: request), as: UTF8.self)
        #expect(text.hasPrefix(#"{"hookSpecificOutput":{"decision":{"behavior":"allow","updatedInput":{"#))
        #expect(text.contains(#""answers":{"Which framework?":"Vue"}"#))
        #expect(text.hasSuffix(#""hookEventName":"PermissionRequest"}}"#))
    }

    /// The real hook script against the real socket: the island's answer comes out on stdout,
    /// and nothing at all when the island has none (Claude Code then asks in its own window).
    @Test func theHookScriptPassesTheAnswersThrough() throws {
        let request = try #require(ApprovalRequest.parse(Bytes.data(ask), id: "q"))
        let answers = ApprovalDecision.answers(["Which framework?": "React", "Which extras?": "Tests"])
        #expect(Self.runHook(ask, decision: answers) == String(decoding: answers.output(for: request), as: UTF8.self))
        #expect(Self.runHook(ask, decision: .deny).contains(#""permissionDecision":"deny""#))
        #expect(Self.runHook(ask, decision: nil).isEmpty)
    }

    static func runHook(_ json: String, decision: ApprovalDecision?) -> String {
        let dir = FileManager.default.temporaryDirectory.appending(path: "aq-\(UUID().uuidString.prefix(8))").path
        let path = dir + "/a.sock"
        let server = ApprovalServer(path: path, handler: { _, reply in reply(decision) })
        defer { server.stop(); try? FileManager.default.removeItem(atPath: dir) }
        guard (try? server.start()) != nil else { return "server failed" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [SetupSandbox.repo.appending(path: "integrations/claude-code/starnotch-approvals/scripts/ask-notch.sh").path]
        process.environment = ["STARNOTCH_SOCKET": path, "HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        guard (try? process.run()) != nil else { return "run failed" }
        input.fileHandleForWriting.write(Data(json.utf8))
        try? input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @Test func denyCarriesTheNoteWhereTheToolTakesOne() throws {
        let bash = #"{"session_id":"s1","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}"#
        let claude = try #require(ApprovalRequest.parse(Bytes.data(bash), id: "r"))
        #expect(claude.takesNote)
        let note = ApprovalDecision.decline("Use make clean")
        #expect(String(decoding: note.output(for: claude), as: UTF8.self)
                == #"{"hookSpecificOutput":{"decision":{"behavior":"deny","message":"Denied from the notch. The user says: Use make clean"},"hookEventName":"PermissionRequest"}}"#)
        var codex = claude
        codex.provider = "codex"
        #expect(String(decoding: note.output(for: codex), as: UTF8.self).contains("The user says: Use make clean"))
        var copilot = claude
        copilot.provider = "copilot"
        #expect(String(decoding: note.output(for: copilot), as: UTF8.self).contains(#""behavior":"deny""#))
        var cursor = claude
        cursor.provider = "cursor"
        #expect(String(decoding: note.output(for: cursor), as: UTF8.self).contains("The user denied this from the notch. The user says: Use make clean"))
        // opencode's reply has no room for it: a plain reject, and no "Instead…" offered.
        var opencode = claude
        opencode.provider = "opencode"
        #expect(!opencode.takesNote)
        #expect(String(decoding: note.output(for: opencode), as: UTF8.self) == #"{"reply":"reject"}"#)
    }
}
