import Darwin
import Foundation

/// A permission request, as a `PermissionRequest` hook receives it on stdin and forwards it to
/// the notch (see integrations/claude-code/starnotch-approvals). Claude Code and Codex send the
/// same fields; the hook script adds `starnotch_provider` for tools other than Claude Code.
/// Claude Code's questions with options (`AskUserQuestion`) come the same way, through a
/// `PreToolUse` hook, and are answered with the picked options.
public struct ApprovalRequest: Equatable, Sendable, Identifiable {
    /// One of Claude Code's `AskUserQuestion` questions: its text, a short header, the options
    /// (label and what it means), and whether several can be picked.
    public struct Question: Equatable, Sendable {
        public struct Option: Equatable, Sendable {
            public var label: String
            public var detail: String?
            public init(label: String, detail: String? = nil) { self.label = label; self.detail = detail }
        }
        public var text: String
        public var header: String?
        public var options: [Option]
        public var multiSelect: Bool
        public init(text: String, header: String? = nil, options: [Option], multiSelect: Bool = false) {
            self.text = text
            self.header = header
            self.options = options
            self.multiSelect = multiSelect
        }

        /// Claude Code asks one to four questions with two to four options each; more is cut.
        static let maxQuestions = 4
        static let maxOptions = 6

        static func parse(_ value: Any?) -> [Question] {
            let questions = (value as? [[String: Any]] ?? []).compactMap { item -> Question? in
                guard let text = (item["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
                let options = (item["options"] as? [Any] ?? []).compactMap { option -> Option? in
                    // An option is {label, description}; a plain string is taken as its label.
                    if let label = (option as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty { return Option(label: label) }
                    guard let object = option as? [String: Any],
                          let label = (object["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else { return nil }
                    let detail = (object["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return Option(label: label, detail: detail?.isEmpty == false ? detail : nil)
                }
                let header = (item["header"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return Question(text: text, header: header?.isEmpty == false ? header : nil,
                                options: Array(options.prefix(maxOptions)), multiSelect: item["multiSelect"] as? Bool ?? false)
            }
            return Array(questions.prefix(maxQuestions))
        }
    }

    public var id: String
    /// `ClaudeCodeProvider.id` or `CodexProvider.id`: decides the reply format.
    public var provider: String = "claude-code"
    public var sessionID: String?
    public var cwd: String?
    public var tool: String
    /// One line for the card: the command, the file, the URL.
    public var summary: String
    /// The full text behind the summary (shown on hover).
    public var detail: String
    /// `permission_suggestions` that add allow rules, kept for "Allow for session".
    public var allowRules: [[String: String]]
    /// An agent's question through the MCP server: up to four answers to pick from …
    public var options: [String] = []
    /// … and/or a field to type the answer.
    public var freeText = false
    /// The agent's process and terminal, when the hook script reports them (tools other than
    /// Claude Code and Codex), so the session can be found and jumped to.
    public var pid: Int32?
    public var tty: String?
    /// Claude Code's `AskUserQuestion`: the questions to answer in the notch.
    public var questions: [Question] = []
    /// The hook event that asked (`PermissionRequest`, or `PreToolUse` for a question): the
    /// reply takes that event's shape.
    public var hookEvent = "PermissionRequest"
    /// The tool's input as it came (JSON), sent back with the answers: Claude Code wants the
    /// original questions echoed.
    public var toolInput: Data?

    /// A question that wants an answer rather than yes or no.
    public var asksForAnswer: Bool { !options.isEmpty || freeText || !questions.isEmpty }

    /// An agent asks something (the MCP server's question, or Claude Code's `AskUserQuestion`)
    /// rather than wanting permission.
    public var isQuestion: Bool { provider == Self.mcpProvider || !questions.isEmpty }

    /// Deny can carry what to do instead: the tools whose reply has room for a message.
    public var takesNote: Bool { !isQuestion && ["claude-code", "codex", "cursor", "copilot"].contains(provider) }

    /// What ↵ does on this card in the agents inbox, whose key monitor sees it before the card's
    /// fields: the same as the card's own ↵, never Allow while a note or an answer is under way.
    public func inboxReturn(noting: Bool) -> InboxReturn {
        if !questions.isEmpty { return .nextQuestion }
        if noting { return .sendNote }
        if freeText { return .field }
        return .primary
    }

    /// The answers Claude Code takes for `questions`: per question the picked labels in the
    /// options' order, joined with ", ", and a typed answer (in place of the pick for a single
    /// choice, added to the picks for several). Questions without either are left out.
    public func answers(picks: [Int: Set<Int>], typed: [Int: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (index, question) in questions.enumerated() {
            var parts = (picks[index] ?? []).sorted().filter(question.options.indices.contains).map { question.options[$0].label }
            if let text = typed[index]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                parts = question.multiSelect ? parts + [text] : [text]
            }
            if !parts.isEmpty { result[question.text] = parts.joined(separator: ", ") }
        }
        return result
    }

    /// The hook's stdin JSON; nil unless it is a PermissionRequest with a tool name.
    public static func parse(_ data: Data, id: String = UUID().uuidString) -> ApprovalRequest? {
        guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // Cursor, Copilot CLI and opencode ask in their own words: put them in Claude Code's.
        if object["hook_event_name"] as? String != "PermissionRequest", let normalized = ProviderApprovals.normalize(object) {
            object = normalized
        }
        let event = object["hook_event_name"] as? String
        guard let tool = object["tool_name"] as? String, !tool.isEmpty,
              event == "PermissionRequest" || (event == "PreToolUse" && tool == "AskUserQuestion") else { return nil }
        let input = object["tool_input"] as? [String: Any] ?? [:]
        let questions = tool == "AskUserQuestion" ? Question.parse(input["questions"]) : []
        // A question hook with nothing to show: Claude Code asks in its own window.
        if event == "PreToolUse" && questions.isEmpty { return nil }
        var (summary, detail) = describe(tool: tool, input: input)
        if !questions.isEmpty {
            summary = questions[0].text
            detail = questions.map(\.text).joined(separator: "\n")
        }
        var rules: [[String: String]] = []
        for suggestion in object["permission_suggestions"] as? [[String: Any]] ?? [] {
            guard suggestion["type"] as? String == "addRules", suggestion["behavior"] as? String == "allow" else { continue }
            for rule in suggestion["rules"] as? [[String: Any]] ?? [] {
                guard let name = rule["toolName"] as? String else { continue }
                var entry = ["toolName": name]
                if let content = rule["ruleContent"] as? String { entry["ruleContent"] = content }
                rules.append(entry)
            }
        }
        var request = ApprovalRequest(id: id, sessionID: object["session_id"] as? String, cwd: object["cwd"] as? String,
                                      tool: tool, summary: summary, detail: detail, allowRules: rules)
        if let provider = (object["starnotch_provider"] as? String)?.nilIfEmpty { request.provider = provider }
        request.hookEvent = event ?? "PermissionRequest"
        if !questions.isEmpty, request.provider == "claude-code" {
            request.questions = questions
            request.toolInput = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
        }
        request.pid = (object["starnotch_pid"] as? NSNumber).map { Int32(clamping: $0.intValue) }.flatMap { $0 > 1 ? $0 : nil }
        request.tty = (object["starnotch_tty"] as? String).flatMap { TerminalJump.isSafe(tty: $0) ? $0 : nil }
        if request.provider == mcpProvider {
            let options = (object["starnotch_options"] as? [String] ?? [])
                .map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)) }
                .filter { !$0.isEmpty }
            request.options = Array(options.prefix(4))
            request.freeText = object["starnotch_free_text"] as? Bool ?? false
        }
        return request
    }

    public init(id: String, provider: String = "claude-code", sessionID: String?, cwd: String?, tool: String,
                summary: String, detail: String, allowRules: [[String: String]]) {
        self.id = id
        self.provider = provider
        self.sessionID = sessionID
        self.cwd = cwd
        self.tool = tool
        self.summary = summary
        self.detail = detail
        self.allowRules = allowRules
    }

    /// Questions from any agent through Starnotch's MCP server (`mcp/`): `tool` names the asking
    /// client, `summary` and `detail` carry the question; the answer is allow (yes) or deny (no).
    public static let mcpProvider = "mcp"

    /// "Allow for session" adds a rule in Claude Code and answers "always" in opencode; for
    /// Cursor and Copilot CLI the notch keeps it (`SessionAllowances`). Codex can't take one.
    public var supportsSessionRules: Bool { questions.isEmpty && ["claude-code", "opencode", "cursor", "copilot"].contains(provider) }

    /// How long the card waits for a click. Cursor's and Copilot's hooks run before every call,
    /// also those the tool would allow on its own, so they wait less.
    public var timeout: TimeInterval { provider == "cursor" || provider == "copilot" ? 30 : 60 }

    /// The session's id in the agents list (Codex ids carry the provider).
    public var agentID: String? {
        guard let sessionID else { return nil }
        return provider == "claude-code" ? sessionID : "\(provider):\(sessionID)"
    }

    static func describe(tool: String, input: [String: Any]) -> (String, String) {
        func string(_ key: String) -> String? {
            // Codex may send a command as an argument list.
            let value = input[key] as? String ?? (input[key] as? [String]).map { $0.joined(separator: " ") }
            return value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let full: String = switch tool {
        case "Bash": string("command") ?? ""
        case "Edit", "Write", "MultiEdit", "Read", "NotebookEdit": string("file_path") ?? string("notebook_path") ?? ""
        case "WebFetch": string("url") ?? ""
        case "WebSearch": string("query") ?? ""
        case "apply_patch":
            // Codex: a patch; the files it touches say more than its first line.
            Self.patchFiles(string("command") ?? "").map { "Edit " + $0 } ?? (string("command") ?? "")
        default:
            string("command") ?? string("file_path") ?? string("url") ?? string("description")
                ?? input.keys.sorted().prefix(3).joined(separator: ", ")
        }
        let line = full.split(whereSeparator: \.isNewline).first.map(String.init) ?? full
        if tool == "apply_patch" { return (line, string("command").map { $0.count > 2000 ? String($0.prefix(2000)) + "…" : $0 } ?? full) }
        let summary = line.count > 120 ? String(line.prefix(119)) + "…" : line
        return (summary, full.count > 2000 ? String(full.prefix(2000)) + "…" : full)
    }
}

extension ApprovalRequest {
    /// "a.swift, b.swift" from a Codex patch's "*** Update File: …" lines.
    static func patchFiles(_ patch: String) -> String? {
        let files = patch.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            for marker in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] where line.hasPrefix(marker) {
                return (String(line.dropFirst(marker.count)) as NSString).lastPathComponent
            }
            return nil
        }
        return files.isEmpty ? nil : files.joined(separator: ", ")
    }
}

/// What the user clicked in the notch.
/// ↵ on a prompt in the agents inbox.
public enum InboxReturn: Equatable, Sendable {
    /// The answer field takes it (it sends what's typed).
    case field
    /// "Instead…" is open: the deny goes with the note.
    case sendNote
    /// Claude Code's questions: the next one, or send.
    case nextQuestion
    /// The inbox's own ↵: allow once, nothing for a question with answers to pick.
    case primary
}

public enum ApprovalDecision: Equatable, Sendable {
    case allowOnce, allowSession, deny
    /// The answer to an agent's question (an option or typed text), for the MCP server only.
    case answer(String)
    /// Answers to Claude Code's `AskUserQuestion`: question text → the picked label (several
    /// joined with ", ") or the typed answer.
    case answers([String: String])
    /// Deny, with what the agent should do instead.
    case decline(String)

    /// "Denied from the notch.", or the user's words with it.
    var denyMessage: String {
        if case .decline(let note) = self, !note.isEmpty { return "Denied from the notch. The user says: \(note)" }
        return "Denied from the notch."
    }

    var isDeny: Bool {
        switch self {
        case .deny, .decline: true
        default: false
        }
    }

    /// The hook's stdout for the request's tool.
    public func output(for request: ApprovalRequest) -> Data {
        switch request.provider {
        case ApprovalRequest.mcpProvider: return ApprovalFormat.mcp(self)
        case "codex": return ApprovalFormat.codex(self)
        case "cursor": return ApprovalFormat.cursor(self)
        case "copilot": return ApprovalFormat.copilot(self)
        case "opencode": return ApprovalFormat.opencode(self)
        default: return claudeOutput(for: request)
        }
    }

    /// Claude Code's stdout, exactly as its PermissionRequest decision control documents it.
    func claudeOutput(for request: ApprovalRequest) -> Data {
        if request.hookEvent == "PreToolUse" { return claudePreToolUse(for: request) }
        var decision: [String: Any]
        switch self {
        case .answers(let answers):
            // A question that came as a permission prompt: allowed with the answers in its input.
            guard let input = Self.answeredInput(request, answers) else { return Data() }
            decision = ["behavior": "allow", "updatedInput": input]
        case .allowOnce, .answer:
            decision = ["behavior": "allow"]
        case .allowSession:
            // Claude Code's own suggestions, kept in memory for this session only. Without one,
            // a Bash command is allowed for exactly this command; another tool as a whole.
            var rules: [[String: String]] = request.allowRules
            if rules.isEmpty {
                rules = request.tool == "Bash" && !request.detail.isEmpty
                    ? [["toolName": "Bash", "ruleContent": request.detail]]
                    : [["toolName": request.tool]]
            }
            decision = ["behavior": "allow",
                        "updatedPermissions": [["type": "addRules", "rules": rules, "behavior": "allow",
                                                "destination": "session"]]]
        case .deny, .decline:
            decision = ["behavior": "deny", "message": denyMessage]
        }
        let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        return (try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])) ?? Data()
    }

    /// The `PreToolUse` reply to `AskUserQuestion`: allow with the original questions and the
    /// answers (Claude Code's documented way; allow alone isn't enough), or deny. Anything else
    /// is no reply, and Claude Code asks in its own window.
    func claudePreToolUse(for request: ApprovalRequest) -> Data {
        var output: [String: Any] = ["hookEventName": "PreToolUse"]
        switch self {
        case .answers(let answers):
            guard let input = Self.answeredInput(request, answers) else { return Data() }
            output["permissionDecision"] = "allow"
            output["updatedInput"] = input
        case .deny, .decline:
            output["permissionDecision"] = "deny"
            output["permissionDecisionReason"] = "The user didn't answer from the notch."
        default:
            return Data()
        }
        return (try? JSONSerialization.data(withJSONObject: ["hookSpecificOutput": output], options: [.sortedKeys])) ?? Data()
    }

    /// The tool's input as it came, with `answers` for the questions asked (unknown questions
    /// and empty answers are left out); nil when nothing is answered.
    static func answeredInput(_ request: ApprovalRequest, _ answers: [String: String]) -> [String: Any]? {
        guard let data = request.toolInput, var input = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let asked = Set(request.questions.map(\.text))
        let kept = answers.filter { asked.contains($0.key) }.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.value.isEmpty }
        guard !kept.isEmpty else { return nil }
        input["answers"] = kept
        return input
    }
}

/// Reply formats per tool.
public enum ApprovalFormat {
    /// The MCP server's reply: the PermissionRequest shape (yes is allow, no is deny) plus the
    /// answer to a question.
    public static func mcp(_ decision: ApprovalDecision) -> Data {
        var output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest",
                                                            "decision": ["behavior": decision.isDeny ? "deny" : "allow"]]]
        if case .answer(let text) = decision { output["starnotch_answer"] = text }
        return (try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])) ?? Data()
    }

    /// Codex's PermissionRequest output: allow or deny only. Codex fails closed on
    /// `updatedPermissions`, so "for this session" can't be expressed and is sent as a plain allow.
    public static func codex(_ decision: ApprovalDecision) -> Data {
        let body: [String: Any] = switch decision {
        case .allowOnce, .allowSession, .answer, .answers: ["behavior": "allow"]
        case .deny, .decline: ["behavior": "deny", "message": decision.denyMessage]
        }
        let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": body]]
        return (try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])) ?? Data()
    }
}

extension ApprovalFormat {
    /// Cursor's `beforeShellExecution`/`beforeMCPExecution` output. No rule for the session.
    public static func cursor(_ decision: ApprovalDecision) -> Data {
        let output: [String: Any] = switch decision {
        case .allowOnce, .allowSession, .answer, .answers: ["permission": "allow"]
        case .deny, .decline: ["permission": "deny", "user_message": decision.denyMessage,
                                     "agent_message": decision.denyMessage.replacingOccurrences(of: "Denied from the notch.", with: "The user denied this from the notch.")]
        }
        return (try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])) ?? Data()
    }

    /// Copilot CLI's `permissionRequest` output (`behavior`, not preToolUse's `permissionDecision`).
    public static func copilot(_ decision: ApprovalDecision) -> Data {
        let output: [String: Any] = switch decision {
        case .allowOnce, .allowSession, .answer, .answers: ["behavior": "allow"]
        case .deny, .decline: ["behavior": "deny", "message": decision.denyMessage]
        }
        return (try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])) ?? Data()
    }

    /// The reply Starnotch's opencode plugin posts to opencode (`/permission/<id>/reply`).
    public static func opencode(_ decision: ApprovalDecision) -> Data {
        let reply = switch decision {
        case .allowOnce, .answer, .answers: "once"
        case .allowSession: "always"
        case .deny, .decline: "reject"
        }
        return Data(#"{"reply":"\#(reply)"}"#.utf8)
    }
}

/// "Allow for session" for tools whose hooks can't carry a rule (Cursor, Copilot CLI): the notch
/// remembers it for that session and answers the same request itself. A shell command is
/// allowed exactly as it was asked; any other tool as a whole, as Claude Code's fallback rule does.
public struct SessionAllowances: Equatable, Sendable {
    static let limit = 200
    private var keys: [String] = []

    public init() {}

    static func key(_ request: ApprovalRequest) -> String? {
        guard let session = request.sessionID, ["cursor", "copilot"].contains(request.provider) else { return nil }
        return [request.provider, session, request.tool, request.tool == "Bash" ? request.detail : ""].joined(separator: "\u{1F}")
    }

    public mutating func allow(_ request: ApprovalRequest) {
        guard let key = Self.key(request), !keys.contains(key) else { return }
        keys.append(key)
        if keys.count > Self.limit { keys.removeFirst(keys.count - Self.limit) }
    }

    public func covers(_ request: ApprovalRequest) -> Bool {
        Self.key(request).map(keys.contains) ?? false
    }
}

/// Permission prompts of tools whose hooks speak their own words, put in Claude Code's
/// `PermissionRequest` shape (tool_name, tool_input, session_id, cwd) so one card serves all.
public enum ProviderApprovals {
    public static func normalize(_ object: [String: Any]) -> [String: Any]? {
        guard let provider = object["starnotch_provider"] as? String else { return nil }
        let event = (object["starnotch_event"] as? String) ?? (object["hook_event_name"] as? String) ?? ""
        let fields = HookFields(object)
        var tool: String
        var input: [String: Any]
        let session: String?
        switch (provider, event) {
        case ("cursor", "beforeShellExecution"):
            guard let command = fields.string("command") else { return nil }
            tool = "Bash"
            input = ["command": command]
            session = fields.string("conversation_id")
        case ("cursor", "beforeMCPExecution"):
            tool = fields.string("tool_name") ?? "MCP"
            input = fields.jsonObject("tool_input") ?? [:]
            if input.isEmpty, let url = fields.string("url") ?? fields.string("command") { input = ["command": url] }
            session = fields.string("conversation_id")
        case ("copilot", "permissionRequest"), ("copilot", "PermissionRequest"):
            guard let name = fields.string("toolName") ?? fields.string("tool_name") else { return nil }
            tool = name
            // Copilot CLI 1.0 sends `toolInput` (an object); older builds `toolArgs` (JSON text).
            input = fields.object("toolInput") ?? fields.jsonObject("toolArgs") ?? fields.object("tool_input") ?? [:]
            session = fields.string("sessionId") ?? fields.string("session_id")
        case ("opencode", "permission.asked"):
            tool = fields.string("permission") ?? "tool"
            let patterns = fields.strings("patterns")
            let metadata = fields.object("metadata") ?? [:]
            input = metadata
            if input["command"] == nil, tool == "bash", !patterns.isEmpty { input["command"] = patterns.joined(separator: " ") }
            if input["file_path"] == nil, let file = (metadata["filepath"] as? String) ?? (metadata["filePath"] as? String) {
                input["file_path"] = file
            }
            if input["description"] == nil, let title = fields.string("title") ?? patterns.first { input["description"] = title }
            session = fields.string("session_id")
        default:
            return nil
        }
        // The card's words for a shell command and a file edit are Claude Code's tool names.
        switch tool.lowercased() {
        case "bash", "shell", "run_shell_command": tool = "Bash"
        case "edit", "write": tool = "Edit"
        case "webfetch", "fetch": tool = "WebFetch"
        default: break
        }
        var result = object
        result["hook_event_name"] = "PermissionRequest"
        result["tool_name"] = tool
        result["tool_input"] = input
        result["session_id"] = session ?? (object["starnotch_pid"] as? NSNumber).map { "pid-\($0.intValue)" }
        return result
    }
}

/// The notch's end of the approvals socket: a Unix socket in the app's support folder (folder
/// 0700, socket 0600). Each connection carries one request; the reply is the hook's stdout (or
/// nothing, which leaves Claude Code's own prompt in charge). Only processes of the same user
/// are served.
public final class ApprovalServer: @unchecked Sendable {
    public typealias Handler = @Sendable (ApprovalRequest, _ reply: @escaping @Sendable (ApprovalDecision?) -> Void) -> Void

    public static let maxRequest = 512 * 1024
    public let path: String
    private let handler: Handler
    private let onCancel: @Sendable (String) -> Void
    private let onEvent: @Sendable (Data) -> Void
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "approvals.accept")

    /// - Parameters:
    ///   - handler: gets each request; call `reply` once (nil = no decision).
    ///   - onCancel: the hook went away before a reply (answered in the terminal): the request id.
    ///   - onEvent: a line that isn't a permission request (a status hook of another tool, see
    ///     `HookUpdate`): its bytes. No reply is written; the connection closes.
    public init(path: String, handler: @escaping Handler, onCancel: @escaping @Sendable (String) -> Void = { _ in },
                onEvent: @escaping @Sendable (Data) -> Void = { _ in }) {
        self.path = path
        self.handler = handler
        self.onCancel = onCancel
        self.onEvent = onEvent
    }

    public func start() throws {
        let folder = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        chmod(folder, 0o700)
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { close(fd); throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        // No umask around bind: it is process-wide, and a folder another thread made meanwhile
        // came out without its execute bit. The 0700 folder already keeps others off the socket.
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else { close(fd); throw POSIXError(.EADDRINUSE) }
        chmod(path, 0o600)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        // Accept through a dispatch source: cancelling it is the only place the descriptor is
        // closed, so no thread can ever accept on a reused descriptor number.
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { return }
                self?.serve(client)
            }
        }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    public func stop() {
        source?.cancel()
        source = nil
        unlink(path)
    }

    private func serve(_ client: Int32) {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { close(client); return }
        // Accepted sockets inherit the listener's non-blocking flag; reads here block (with a timeout).
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        DispatchQueue.global(qos: .userInitiated).async { [handler, onCancel, onEvent] in
            // Read until the bytes parse as one request (the hook sends JSON, then closes its write side or not).
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 16_384)
            var request: ApprovalRequest?
            while data.count < Self.maxRequest {
                let n = read(client, &buffer, buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
                if let parsed = ApprovalRequest.parse(data) { request = parsed; break }
                // The hook sends one line; a full line that isn't a request ends it.
                if data.contains(0x0A) { break }
            }
            guard let request else {
                close(client)
                if !data.isEmpty { onEvent(data) }
                return
            }
            let state = Once()
            let finish: @Sendable (ApprovalDecision?) -> Void = { decision in
                guard state.claim() else { return }
                if let decision {
                    let out = decision.output(for: request)
                    _ = out.withUnsafeBytes { write(client, $0.baseAddress, out.count) }
                }
                // The watcher below owns the descriptor and closes it, only after this point.
                shutdown(client, SHUT_RDWR)
                state.finish()
            }
            handler(request, finish)
            // The hook keeps its side open and sends a newline now and then while it waits; end
            // of stream means it is gone (Claude Code took the answer in the terminal).
            DispatchQueue.global(qos: .utility).async {
                var sink = [UInt8](repeating: 0, count: 256)
                defer {
                    // Close only once the reply is written (a reply racing a close could otherwise
                    // land on a reused descriptor).
                    while !state.isFinished { usleep(10_000) }
                    close(client)
                }
                while !state.isDone {
                    var poller = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
                    guard poll(&poller, 1, 250) > 0 else { continue }
                    let n = recv(client, &sink, sink.count, MSG_DONTWAIT)
                    if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
                        if state.isDone { return }
                        finish(nil)
                        onCancel(request.id)
                        return
                    }
                }
            }
        }
    }
}

/// A flag that flips once, safely from any thread.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var finished = false

    var isDone: Bool { lock.lock(); defer { lock.unlock() }; return done }
    /// The claimant has completed its work.
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    func finish() { lock.lock(); finished = true; lock.unlock() }

    /// True for the first caller only.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
