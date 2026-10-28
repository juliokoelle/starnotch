import Foundation

// Ask Tara: the `ask` command to the sidecar and its `answer` (agent/PROTOCOL.md), without any UI.

/// Where a fact in Tara's answer comes from: a meeting, a quick capture, or a note from a connector.
public struct AskSource: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case meeting, capture, note }

    public var id: String
    public var kind: Kind
    public var title: String
    /// The exact words from the source; may be empty for a note.
    public var quote: String
    public var speaker: String?
    /// `YYYY-MM-DD`, if the source has one.
    public var date: String?
    /// Where a click goes (a note's file or link); nil for meetings.
    public var url: URL?

    public init(id: String, kind: Kind, title: String, quote: String = "", speaker: String? = nil,
                date: String? = nil, url: URL? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.quote = quote
        self.speaker = speaker
        self.date = date
        self.url = url
    }
}

public struct AskAnswer: Equatable, Sendable {
    public var question: String
    public var text: String
    public var sources: [AskSource]
    /// What answered: `claude-code`, `api` or `rules`.
    public var brain: String

    public init(question: String, text: String, sources: [AskSource] = [], brain: String = "rules") {
        self.question = question
        self.text = text
        self.sources = sources
        self.brain = brain
    }

    /// No model answered: the closest line the rules found, or what Tara can do without a brain.
    public var onRules: Bool { brain == "rules" }
}

/// What `agent.py` says back to Ask Tara. Lines it doesn't care about give `nil`.
public enum AskReply: Equatable, Sendable {
    case ready(brain: String)
    case answer(AskAnswer, replyTo: String?)
    case failed(String, replyTo: String?)
    /// Claude isn't reachable; the agent answers on rules.
    case offline(String)

    public static func parse(_ data: Data) -> AskReply? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        let s = MeetingLine.string
        switch type {
        case "ready":
            return .ready(brain: s(object["brain"]) ?? "rules")
        case "answer":
            guard let text = s(object["text"]) else { return nil }
            let sources = (object["sources"] as? [[String: Any]] ?? []).enumerated().compactMap { index, item in
                source(item, index: index)
            }
            let answer = AskAnswer(question: s(object["question"]) ?? "", text: text, sources: sources,
                                   brain: s(object["brain"]) ?? "rules")
            return .answer(answer, replyTo: replyTo(object))
        case "error":
            return .failed(s(object["message"]) ?? "error", replyTo: replyTo(object))
        case "status":
            guard s(object["state"]) == "offline" else { return nil }
            return .offline(s(object["message"]) ?? "")
        default:
            return nil
        }
    }

    private static func source(_ item: [String: Any], index: Int) -> AskSource? {
        let s = MeetingLine.string
        let kind = AskSource.Kind(rawValue: s(item["kind"]) ?? "meeting") ?? .meeting
        guard let title = s(item["title"]) ?? s(item["meeting"]) ?? s(item["quote"]) else { return nil }
        let link = s(item["url"]).flatMap { URL(string: $0) }
        return AskSource(id: "\(index)-\(s(item["id"]) ?? s(item["meeting_id"]) ?? title)", kind: kind, title: title,
                         quote: s(item["quote"]) ?? "", speaker: s(item["speaker"]),
                         date: s(item["date"]).map { String($0.prefix(10)) }, url: link)
    }

    /// `reply_to` as the app sent it (a string id), or nil.
    private static func replyTo(_ object: [String: Any]) -> String? {
        switch object["reply_to"] {
        case let text as String: text
        case let number as NSNumber: number.stringValue
        default: nil
        }
    }
}

/// The short conversation behind follow-ups: the last few questions and answers.
public struct AskConversation: Equatable, Sendable {
    public struct Turn: Equatable, Sendable {
        public var question: String
        public var answer: String
    }

    /// As many turns as the sidecar reads (agent.py `HISTORY`).
    public static let limit = 6
    public private(set) var turns: [Turn] = []

    public init() {}

    public mutating func append(question: String, answer: String) {
        turns.append(Turn(question: question, answer: answer))
        if turns.count > Self.limit { turns.removeFirst(turns.count - Self.limit) }
    }

    public mutating func clear() { turns = [] }
}

/// The `ask` line for `agent.py`, newline included.
public enum AskCommand {
    public static func ask(_ question: String, conversation: AskConversation = AskConversation(),
                           image: String? = nil, id: String) -> Data {
        Data((text(question, conversation: conversation, image: image, id: id) + "\n").utf8)
    }

    /// The same line as text, without the newline (sorted keys, so it reads the same every time).
    public static func text(_ question: String, conversation: AskConversation = AskConversation(),
                            image: String? = nil, id: String) -> String {
        var object: [String: Any] = ["cmd": "ask", "question": question, "id": id]
        if !conversation.turns.isEmpty {
            object["history"] = conversation.turns.map { ["question": $0.question, "answer": $0.answer] }
        }
        if let image { object["image"] = image }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// ⌃⌥T: a tap opens Ask Tara (or closes it when open); held, Tara listens until the keys come up.
/// The press decides at once only when Ask is closed (open immediately, it feels instant); when
/// it's open the release decides, since a tap closes and a hold talks.
public struct AskHotKeyGesture: Equatable, Sendable {
    public enum Press: Equatable, Sendable { case open, wait }
    public enum Release: Equatable, Sendable { case close, send, nothing }

    /// Held this long, the keys mean "listen".
    public static let holdThreshold: TimeInterval = 0.35

    private var pressed: Date?
    private var wasOpen = false
    public private(set) var listening = false

    public init() {}

    public mutating func press(at time: Date, isOpen: Bool) -> Press {
        pressed = time
        wasOpen = isOpen
        listening = false
        return isOpen ? .wait : .open
    }

    /// Still held after the threshold: start listening (true once per press).
    public mutating func holdElapsed(at time: Date) -> Bool {
        guard let pressed, !listening, time.timeIntervalSince(pressed) >= Self.holdThreshold else { return false }
        listening = true
        return true
    }

    public mutating func release(at time: Date) -> Release {
        defer { pressed = nil; listening = false }
        guard let pressed else { return .nothing }
        if listening || time.timeIntervalSince(pressed) >= Self.holdThreshold { return .send }
        return wasOpen ? .close : .nothing
    }
}
