import Foundation

/// What a Codex rollout (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`) says, fed line by line so
/// the file can be read incrementally. Understands both formats seen so far: the older one
/// (`user_message`, `agent_message`, `exec_command_begin` events) and the paginated one of
/// Codex 0.15x and later (`task_started`, `item_completed`, `token_count`, items in a database).
public struct CodexRollout: Equatable, Sendable {
    public enum Phase: String, Sendable {
        case unknown, working, done, aborted
    }

    public var threadID: String?
    public var cwd: String?
    public var branch: String?
    public var originator: String?
    /// `cli`, `exec`, `vscode` (the desktop app and the IDE extension), or a subagent's JSON.
    public var source: String?
    /// Spawned subagent: its parent thread and nickname.
    public var parentThreadID: String?
    public var nickname: String?
    /// The automatic reviewer Codex runs before risky actions; not a session of its own.
    public var isGuardian = false
    public var model: String?
    public var effort: String?
    public var phase: Phase = .unknown
    /// Start of the current phase.
    public var phaseSince: Date?
    public var startedAt: Date?
    public var lastDate: Date?
    public var steps: [SessionStep] = []
    public var firstPrompt: String?
    public var lastMessage: String?
    /// Tokens in the context at the last model call, and the window size.
    public var contextTokens: Int?
    public var contextWindow: Int?
    public var totalTokens: Int?
    public var limits: Limits?
    /// Lines with a known shape vs. lines that parse but aren't any known record.
    public var knownLines = 0
    public var unknownLines = 0

    public struct Limits: Equatable, Sendable {
        public var primary: AgentUsage.Window?
        public var secondary: AgentUsage.Window?
        public var plan: String?
        public var at: Date
    }

    public init() {}

    static let knownTypes: Set<String> = ["session_meta", "event_msg", "response_item", "turn_context", "compacted",
                                          "world_state", "token_usage_record", "message", "reasoning", "function_call",
                                          "function_call_output"]

    /// Too many lines of an unknown shape: the format changed, show nothing rather than nonsense.
    public var formatLooksUnknown: Bool {
        let total = knownLines + unknownLines
        return total >= 8 && unknownLines * 2 > total
    }

    /// Feeds complete lines (a partial last line must be held back by the caller).
    public mutating func feed(lines text: Substring) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            feed(object)
        }
    }

    mutating func feed(_ object: [String: Any]) {
        guard let type = object["type"] as? String, Self.knownTypes.contains(type) else {
            unknownLines += 1
            return
        }
        knownLines += 1
        let date = (object["timestamp"] as? String).flatMap(SessionLog.parseDate)
        if let date { lastDate = max(lastDate ?? date, date) }
        let payload = object["payload"] as? [String: Any] ?? [:]
        switch type {
        case "session_meta":
            threadID = payload["id"] as? String ?? threadID
            cwd = payload["cwd"] as? String ?? cwd
            originator = payload["originator"] as? String ?? originator
            if let git = payload["git"] as? [String: Any], let branch = git["branch"] as? String { self.branch = branch }
            if let started = (payload["timestamp"] as? String).flatMap(SessionLog.parseDate) { startedAt = started }
            if let source = payload["source"] as? String {
                self.source = source
            } else if let source = payload["source"] as? [String: Any], let sub = source["subagent"] as? [String: Any] {
                self.source = "subagent"
                if let spawn = sub["thread_spawn"] as? [String: Any] {
                    parentThreadID = spawn["parent_thread_id"] as? String
                    nickname = spawn["agent_nickname"] as? String
                } else if (sub["other"] as? String) == "guardian" {
                    isGuardian = true
                }
            }
            if (payload["thread_source"] as? String) == "guardian_review" { isGuardian = true }
            if parentThreadID == nil, let parent = payload["parent_thread_id"] as? String, parent != threadID, !isGuardian {
                parentThreadID = parent
            }
        case "turn_context":
            model = payload["model"] as? String ?? model
            if let mode = payload["collaboration_mode"] as? [String: Any], let settings = mode["settings"] as? [String: Any],
               let effort = settings["reasoning_effort"] as? String {
                self.effort = effort
            } else if let effort = payload["effort"] as? String {
                self.effort = effort
            }
            if let cwd = payload["cwd"] as? String { self.cwd = cwd }
        case "event_msg":
            event(payload, date: date)
        case "response_item":
            responseItem(payload, date: date)
        default:
            break
        }
    }

    private mutating func set(_ phase: Phase, at date: Date?) {
        if self.phase != phase { phaseSince = date ?? phaseSince }
        self.phase = phase
    }

    private mutating func event(_ payload: [String: Any], date: Date?) {
        switch payload["type"] as? String {
        case "task_started":
            set(.working, at: date)
            if let window = payload["model_context_window"] as? Int { contextWindow = window }
        case "task_complete":
            set(.done, at: date)
            if let message = (payload["last_agent_message"] as? String)?.nilIfEmpty { lastMessage = Self.short(message, 200) }
        case "turn_aborted":
            set(.aborted, at: date)
        case "thread_settings_applied":
            if let settings = payload["thread_settings"] as? [String: Any] {
                model = settings["model"] as? String ?? model
                effort = settings["reasoning_effort"] as? String ?? effort
                cwd = settings["cwd"] as? String ?? cwd
            }
        case "token_count":
            if let info = payload["info"] as? [String: Any] {
                if let last = info["last_token_usage"] as? [String: Any], let tokens = last["total_tokens"] as? Int {
                    contextTokens = tokens
                }
                if let total = info["total_token_usage"] as? [String: Any], let tokens = total["total_tokens"] as? Int {
                    totalTokens = tokens
                }
                if let window = info["model_context_window"] as? Int { contextWindow = window }
            }
            if let limits = payload["rate_limits"] as? [String: Any] {
                let at = date ?? Date()
                func window(_ value: Any?) -> AgentUsage.Window? {
                    guard let dict = value as? [String: Any], let used = (dict["used_percent"] as? NSNumber)?.doubleValue else { return nil }
                    var reset: Date?
                    if let epoch = (dict["resets_at"] as? NSNumber)?.doubleValue {
                        reset = Date(timeIntervalSince1970: epoch)
                    } else if let seconds = (dict["resets_in_seconds"] as? NSNumber)?.doubleValue {
                        reset = at.addingTimeInterval(seconds)
                    }
                    return AgentUsage.Window(usedPercent: used, minutes: (dict["window_minutes"] as? NSNumber)?.intValue, resetsAt: reset)
                }
                let primary = window(limits["primary"]), secondary = window(limits["secondary"])
                if primary != nil || secondary != nil {
                    self.limits = Limits(primary: primary, secondary: secondary, plan: limits["plan_type"] as? String, at: at)
                }
            }
        // Older format.
        case "user_message":
            if let message = (payload["message"] as? String)?.nilIfEmpty {
                if firstPrompt == nil { firstPrompt = Self.short(message, 80) }
                if phase != .working { set(.working, at: date) }
            }
        case "agent_message":
            if let message = (payload["message"] as? String)?.nilIfEmpty {
                lastMessage = Self.short(message, 200)
                push(SessionStep(kind: .message, text: Self.short(message, 90), date: date))
            }
        case "exec_command_begin":
            if let command = Self.command(payload["command"]) { push(SessionStep(kind: .shell, text: command, date: date)) }
        case "patch_apply_begin":
            let files = (payload["changes"] as? [String: Any]).map { $0.keys.map { ($0 as NSString).lastPathComponent }.sorted() } ?? []
            push(SessionStep(kind: .edit, text: files.isEmpty ? "Editing files" : "Edit " + files.joined(separator: ", "), date: date))
        case "web_search_begin", "web_search_end":
            if let query = (payload["query"] as? String)?.nilIfEmpty { push(SessionStep(kind: .web, text: "Search " + query, date: date)) }
        case "mcp_tool_call_begin":
            if let invocation = payload["invocation"] as? [String: Any], let tool = invocation["tool"] as? String {
                push(SessionStep(kind: .tool, text: tool, date: date))
            }
        // Paginated format: finished items.
        case "item_completed":
            if let item = payload["item"] as? [String: Any] { completed(item, date: date) }
        default:
            break
        }
    }

    private mutating func completed(_ item: [String: Any], date: Date?) {
        switch item["type"] as? String {
        case "UserMessage":
            if firstPrompt == nil, let parts = item["content"] as? [[String: Any]],
               let text = parts.compactMap({ $0["text"] as? String }).first {
                firstPrompt = Self.short(Self.request(in: text), 80)
            }
        case "AgentMessage":
            if let parts = item["content"] as? [[String: Any]], let text = parts.compactMap({ $0["text"] as? String }).first?.nilIfEmpty {
                lastMessage = Self.short(text, 200)
                push(SessionStep(kind: .message, text: Self.short(text, 90), date: date))
            }
        case "CommandExecution":
            if let command = Self.command(item["command"]) { push(SessionStep(kind: .shell, text: command, date: date)) }
        case "FileChange":
            let files = (item["changes"] as? [String: Any]).map { $0.keys.map { ($0 as NSString).lastPathComponent }.sorted() } ?? []
            push(SessionStep(kind: .edit, text: files.isEmpty ? "Editing files" : "Edit " + files.prefix(3).joined(separator: ", "), date: date))
        case "McpToolCall":
            if let tool = item["tool"] as? String { push(SessionStep(kind: .tool, text: tool.replacingOccurrences(of: "_", with: " "), date: date)) }
        case "Extension":
            if let query = (item["query"] as? String)?.nilIfEmpty { push(SessionStep(kind: .web, text: "Search " + Self.short(query, 70), date: date)) }
        case "ContextCompaction":
            push(SessionStep(kind: .tool, text: "Compacting context", date: date))
        default:
            break
        }
    }

    private mutating func responseItem(_ payload: [String: Any], date: Date?) {
        switch payload["type"] as? String {
        case "function_call":
            // Older format: the shell tool's arguments carry the command.
            if payload["name"] as? String == "shell", let arguments = payload["arguments"] as? String,
               let data = arguments.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let command = Self.command(object["command"]) {
                push(SessionStep(kind: .shell, text: command, date: date))
            }
        case "message":
            if payload["role"] as? String == "user", firstPrompt == nil,
               let parts = payload["content"] as? [[String: Any]],
               let text = parts.compactMap({ $0["text"] as? String }).first(where: { !$0.hasPrefix("<") }) {
                firstPrompt = Self.short(Self.request(in: text), 80)
            }
        default:
            break
        }
    }

    private mutating func push(_ step: SessionStep) {
        // The older format logs a command twice (the call and its start).
        if let last = steps.last, last.kind == step.kind, last.text == step.text { return }
        steps.append(step)
        if steps.count > SessionLog.maxSteps { steps.removeFirst(steps.count - SessionLog.maxSteps) }
    }

    /// "npm test" from `["/bin/zsh", "-lc", "npm test"]` or a plain string.
    static func command(_ value: Any?) -> String? {
        var text: String?
        if let parts = value as? [String] {
            text = parts.count >= 3 && ["-lc", "-c"].contains(parts[parts.count - 2]) ? parts.last : parts.joined(separator: " ")
        } else if let string = value as? String {
            text = string
        }
        guard let line = text?.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces),
              !line.isEmpty else { return nil }
        return short(line, 90)
    }

    /// The user's own words when Codex wrapped them ("## My request:" after attached files).
    static func request(in text: String) -> String {
        if let range = text.range(of: "## My request:") {
            return String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func short(_ text: String, _ limit: Int) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }
}
