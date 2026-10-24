import Foundation

/// What a subagent's transcript (`<session>/subagents/agent-<id>.jsonl`) says so far. Fed
/// incrementally: whole lines only, in file order, so a scan never re-reads what it has seen.
public struct SubagentProgress: Equatable, Sendable {
    public enum Status: String, Sendable { case running, done, failed, stopped }

    /// First line of what the parent asked it.
    public var task: String?
    public var startedAt: Date?
    public var lastDate: Date?
    /// Most recent steps, oldest first.
    public var steps: [SessionStep] = []
    /// The latest line it wrote.
    public var lastText: String?
    /// Its final report: the handback message, else the closing text of its last turn.
    public var result: String?
    public var toolUses = 0
    public var outputTokens = 0
    /// Tokens in its context at the last message.
    public var contextTokens: Int?
    /// The last record was an API error.
    public var errored = false
    /// Only the opening and the latest part were read: counts cover that part.
    public var partial = false
    /// The last assistant message ended its turn without asking for a tool.
    var endedTurn = false
    var closingText: String?

    public static let maxSteps = 5

    public init() {}

    /// Running while the file still changes; then done (a result), failed (an error) or
    /// stopped (cut off without either).
    public func status(modified: Date, now: Date, quiet: TimeInterval = 120) -> Status {
        if result != nil || (endedTurn && closingText != nil) { return errored ? .failed : .done }
        if errored { return .failed }
        return now.timeIntervalSince(modified) < quiet ? .running : .stopped
    }

    /// The report to show: the handback, else the closing text.
    public var report: String? { result ?? (endedTurn ? closingText : nil) }

    public mutating func feed(lines text: Substring) {
        for line in text.split(whereSeparator: \.isNewline) { feed(line: line) }
    }

    public mutating func feed(line: Substring) {
        guard line.first == "{",
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let type = object["type"] as? String, type == "user" || type == "assistant" else { return }
        let date = (object["timestamp"] as? String).flatMap(SessionLog.parseDate)
        if let date {
            if startedAt == nil { startedAt = date }
            lastDate = date
        }
        guard let message = object["message"] as? [String: Any] else { return }
        if type == "user" {
            if task == nil, let text = message["content"] as? String {
                task = SessionLog.clip(text.split(whereSeparator: \.isNewline).first.map(String.init)?
                    .trimmingCharacters(in: .whitespaces) ?? text, max: 140)
            } else if task == nil, let blocks = message["content"] as? [[String: Any]],
                      let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String {
                task = SessionLog.clip(text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text, max: 140)
            }
            return
        }
        errored = object["isApiErrorMessage"] as? Bool == true
        if let usage = message["usage"] as? [String: Any] {
            outputTokens += (usage["output_tokens"] as? NSNumber)?.intValue ?? 0
            let keys = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
            let total = keys.reduce(0) { $0 + ((usage[$1] as? NSNumber)?.intValue ?? 0) }
            if total > 0 { contextTokens = total }
        }
        guard let content = message["content"] as? [[String: Any]] else { return }
        var usedTool = false
        var text: String?
        for block in content {
            switch block["type"] as? String {
            case "tool_use":
                usedTool = true
                toolUses += 1
                let input = block["input"] as? [String: Any] ?? [:]
                if block["name"] as? String == "SubagentHandback", let message = input["message"] as? String {
                    result = message
                } else {
                    // Working again after a report (a continued subagent): running, not done.
                    result = nil
                    closingText = nil
                }
            case "text":
                if let value = block["text"] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    text = value
                }
            default: break
            }
            if let step = SessionLog.step(from: block, date: date) {
                steps.append(step)
                if steps.count > Self.maxSteps { steps.removeFirst(steps.count - Self.maxSteps) }
            }
        }
        if let text {
            lastText = SessionLog.clip(text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text, max: 160)
        }
        if let stop = message["stop_reason"] as? String {
            endedTurn = stop == "end_turn" && !usedTool
        } else {
            endedTurn = !usedTool && text != nil
        }
        if endedTurn { closingText = text }
    }

    /// The first lines of a report, for the detail card.
    public static func excerpt(_ text: String, lines: Int = 4) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(lines)
            .joined(separator: "\n")
    }
}

/// `agent-<id>.meta.json` next to a subagent's transcript.
public struct SubagentMeta: Decodable, Equatable, Sendable {
    public var agentType: String?
    public var description: String?

    public static func decode(_ data: Data) -> SubagentMeta? { try? JSONDecoder().decode(SubagentMeta.self, from: data) }
}
