import Foundation

/// One thing a Claude Code session did: a tool call or a piece of text it wrote.
public struct SessionStep: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case shell, edit, read, search, web, agent, plan, tool, message
    }

    public var kind: Kind
    public var text: String
    public var date: Date?

    public init(kind: Kind, text: String, date: Date? = nil) {
        self.kind = kind
        self.text = text
        self.date = date
    }
}

/// What the tail of a session transcript (`~/.claude/projects/*/<id>.jsonl`) says.
public struct SessionActivity: Equatable, Sendable {
    /// `custom-title` if the user named the session, else the generated `ai-title`.
    public var title: String?
    public var cwd: String?
    public var branch: String?
    /// The most recent steps, oldest first.
    public var steps: [SessionStep] = []
    /// Timestamp of the last user or assistant record.
    public var lastDate: Date?
    /// The first prompt the user typed in this tail, shortened (fallback title).
    public var firstPrompt: String?
    /// The last thing the assistant wrote.
    public var lastMessage: String?
    /// The latest assistant message's model and effort (`requestedModel`/`message.model`, `effort`).
    public var model: String?
    public var effort: String?
    /// Tokens in the context at the last assistant message (input + cache read + cache write);
    /// after an auto-compaction the next message is small again, so the latest value is right.
    public var contextTokens: Int?

    public init() {}

    public var current: SessionStep? { steps.last }
}

public enum SessionLog {
    public static let maxSteps = 4

    /// Parses JSONL text, typically the last few dozen kilobytes of a transcript. A partial
    /// first line (from reading mid-file) is ignored like any malformed line.
    public static func activity(fromTail text: String) -> SessionActivity {
        var activity = SessionActivity()
        var customTitle: String?
        var aiTitle: String?
        var steps: [SessionStep] = []

        for line in text.split(whereSeparator: \.isNewline) {
            guard line.first == "{",
                  let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            switch type {
            case "custom-title": customTitle = object["customTitle"] as? String ?? customTitle
            case "ai-title": aiTitle = object["aiTitle"] as? String ?? aiTitle
            case "assistant", "user":
                if let cwd = object["cwd"] as? String { activity.cwd = cwd }
                if let branch = object["gitBranch"] as? String, !branch.isEmpty { activity.branch = branch }
                let date = (object["timestamp"] as? String).flatMap(parseDate)
                if let date { activity.lastDate = date }
                if type == "user", activity.firstPrompt == nil, object["isMeta"] as? Bool != true,
                   let message = object["message"] as? [String: Any], let text = message["content"] as? String,
                   !text.hasPrefix("<"), let line = text.split(whereSeparator: \.isNewline).first {
                    activity.firstPrompt = clip(String(line).trimmingCharacters(in: .whitespaces), max: 60)
                }
                if type == "assistant" {
                    if let effort = object["effort"] as? String { activity.effort = effort }
                    if let usage = (object["message"] as? [String: Any])?["usage"] as? [String: Any] {
                        let keys = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
                        let total = keys.reduce(0) { $0 + ((usage[$1] as? NSNumber)?.intValue ?? 0) }
                        if total > 0 { activity.contextTokens = total }
                    }
                    if let model = object["requestedModel"] as? String ?? (object["message"] as? [String: Any])?["model"] as? String {
                        activity.model = model
                    }
                }
                guard type == "assistant",
                      let message = object["message"] as? [String: Any],
                      let content = message["content"] as? [[String: Any]] else { continue }
                for block in content {
                    if let step = step(from: block, date: date) { steps.append(step) }
                }
            default: break
            }
        }
        activity.title = customTitle ?? aiTitle
        activity.lastMessage = steps.last(where: { $0.kind == .message })?.text
        activity.steps = Array(steps.suffix(maxSteps))
        return activity
    }

    static func step(from block: [String: Any], date: Date?) -> SessionStep? {
        switch block["type"] as? String {
        case "tool_use":
            let input = block["input"] as? [String: Any] ?? [:]
            let (kind, text) = describe(tool: block["name"] as? String ?? "Tool", input: input)
            return SessionStep(kind: kind, text: text, date: date)
        case "text":
            guard let text = block["text"] as? String,
                  let line = text.split(whereSeparator: \.isNewline)
                    .map({ $0.trimmingCharacters(in: .whitespaces) })
                    .first(where: { !$0.isEmpty }) else { return nil }
            return SessionStep(kind: .message, text: clip(line, max: 160), date: date)
        default:
            return nil
        }
    }

    /// A short, human description of a tool call, e.g. "Editing TaskList.tsx".
    public static func describe(tool: String, input: [String: Any]) -> (SessionStep.Kind, String) {
        func string(_ key: String) -> String? {
            (input[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        let file = string("file_path").map { ($0 as NSString).lastPathComponent }
            ?? string("notebook_path").map { ($0 as NSString).lastPathComponent }

        switch tool {
        case "Bash":
            if let description = string("description") { return (.shell, clip(description)) }
            return (.shell, clip("Running " + (string("command")?.split(separator: "\n").first.map(String.init) ?? "a command")))
        case "Edit", "MultiEdit", "NotebookEdit":
            return (.edit, "Editing \(file ?? "a file")")
        case "Write":
            return (.edit, "Writing \(file ?? "a file")")
        case "Read":
            return (.read, "Reading \(file ?? "a file")")
        case "Grep":
            return (.search, clip("Searching for \u{201C}\(string("pattern") ?? "…")\u{201D}"))
        case "Glob":
            return (.search, clip("Finding \(string("pattern") ?? "files")"))
        case "Agent", "Task":
            return (.agent, clip("Subagent: \(string("description") ?? "started")"))
        case "ToolSearch":
            return (.tool, "Loading tools")
        case "SendMessage":
            return (.agent, "Messaging a subagent")
        case "WebSearch":
            return (.web, clip("Searching the web: \(string("query") ?? "")"))
        case "WebFetch":
            let host = string("url").flatMap { URL(string: $0)?.host } ?? "a page"
            return (.web, "Reading \(host)")
        case "TodoWrite", "TaskCreate", "TaskUpdate":
            return (.plan, "Updating the plan")
        case "Skill":
            return (.tool, clip("Using skill \(string("skill") ?? "")"))
        default:
            if tool.hasPrefix("mcp__") {
                let parts = tool.dropFirst(5).components(separatedBy: "__")
                let server = (parts.first ?? "")
                    .replacingOccurrences(of: "claude_ai_", with: "")
                    .replacingOccurrences(of: "plugin_", with: "")
                    .replacingOccurrences(of: "_", with: " ")
                let action = (parts.dropFirst().first ?? "").replacingOccurrences(of: "_", with: " ")
                return (.tool, clip("\(server): \(action)"))
            }
            return (.tool, tool)
        }
    }

    static func clip(_ text: String, max: Int = 90) -> String {
        let single = text.replacingOccurrences(of: "\n", with: " ")
        return single.count > max ? String(single.prefix(max - 1)) + "…" : single
    }

    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()

    public static func parseDate(_ string: String) -> Date? {
        fractional.date(from: string) ?? plain.date(from: string)
    }
}

/// A live Claude Code process, from `~/.claude/sessions/<pid>.json`.
public struct SessionRecord: Decodable, Equatable, Sendable {
    public var pid: Int32
    public var sessionId: String
    public var cwd: String
    public var name: String?
    /// `busy` or `idle` as Claude Code reports it.
    public var status: String?
    /// Milliseconds since 1970.
    public var startedAt: Double?
    public var statusUpdatedAt: Double?
    public var entrypoint: String?
    /// `user` when the user named the session, `derived` for generated names.
    public var nameSource: String?
    /// Remote Control id: the session is reachable at claude.ai/code/<id>.
    public var bridgeSessionId: String?

    public init(pid: Int32, sessionId: String, cwd: String, name: String? = nil, status: String? = nil,
                startedAt: Double? = nil, statusUpdatedAt: Double? = nil, entrypoint: String? = nil) {
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = cwd
        self.name = name
        self.status = status
        self.startedAt = startedAt
        self.statusUpdatedAt = statusUpdatedAt
        self.entrypoint = entrypoint
    }

    public static func decode(_ data: Data) -> SessionRecord? {
        try? JSONDecoder().decode(SessionRecord.self, from: data)
    }

    public var isBusy: Bool { status == "busy" }

    /// The user's own name for the session, if they gave one.
    public var userName: String? { nameSource == "user" ? name?.nilIfEmpty : nil }

    public var remoteURL: URL? {
        guard let id = bridgeSessionId, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        return URL(string: "https://claude.ai/code/\(id)")
    }

    /// Background helpers that aren't agents the user started (the claude-mem observer).
    public var isBackgroundHelper: Bool { cwd.contains("/.claude-mem/") }

    public var statusSince: Date? {
        (statusUpdatedAt ?? startedAt).map { Date(timeIntervalSince1970: $0 / 1000) }
    }
}

/// A row of `launchctl list`: `PID  Status  Label`.
public struct LaunchdJob: Equatable, Sendable {
    public var label: String
    public var pid: Int32?
    public var lastExitStatus: Int32

    public init(label: String, pid: Int32?, lastExitStatus: Int32) {
        self.label = label
        self.pid = pid
        self.lastExitStatus = lastExitStatus
    }

    public var isRunning: Bool { pid != nil }

    public static func parse(_ output: String, prefix: String) -> [LaunchdJob] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let columns = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard columns.count >= 3, columns[2].hasPrefix(prefix),
                  let status = Int32(columns[1]) else { return nil }
            return LaunchdJob(label: String(columns[2]), pid: Int32(columns[0]), lastExitStatus: status)
        }
        .sorted { $0.label < $1.label }
    }
}

public enum Durations {
    /// `45s`, `12m`, `2h 5m`, `3d`.
    public static func short(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return s % 3600 / 60 == 0 ? "\(s / 3600)h" : "\(s / 3600)h \(s % 3600 / 60)m" }
        return "\(s / 86_400)d"
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
