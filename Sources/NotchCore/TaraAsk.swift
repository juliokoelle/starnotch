import Foundation

// Ask Tara: the `ask` command to the sidecar and its `answer` (agent/PROTOCOL.md), without any UI.

/// Where a fact in Tara's answer comes from: a meeting, a quick capture, a note from a connector,
/// or screen context ("Screen · Mail · 14:05").
public struct AskSource: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case meeting, capture, note, screen }

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

public struct AskAnswer: Codable, Equatable, Sendable {
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

    /// The answer saved as a Markdown note: the question as its title, the answer, and a line
    /// naming where it came from ("Sources: Kickoff (2026-10-12), Pricing").
    public func note(asked: String? = nil, sourcesLabel: String = "Sources") -> String {
        let title = (asked ?? question).split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        var parts = [title.isEmpty ? "" : "# \(title)", text.trimmingCharacters(in: .whitespacesAndNewlines)]
        let named = sources.map { source in source.date.map { "\(source.title) (\($0))" } ?? source.title }
        if !named.isEmpty { parts.append("\(sourcesLabel): " + named.joined(separator: ", ")) }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n") + "\n"
    }

    /// The answer as one line of the notes inbox, which folds every line break: the question, an
    /// arrow, the answer, and the sources in brackets ("Preis? → 30 Euro. (Sources: Kickoff (2026-10-12))").
    public func inboxLine(asked: String? = nil, sourcesLabel: String = "Sources") -> String {
        func flat(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        let title = flat(asked ?? question)
        var line = title.isEmpty ? flat(text) : "\(title) → \(flat(text))"
        let named = sources.map { source in source.date.map { "\(source.title) (\($0))" } ?? source.title }
        if !named.isEmpty { line += " (\(sourcesLabel): " + named.joined(separator: ", ") + ")" }
        return line
    }
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

/// The Dashboard's chat: the questions already answered (or that went wrong), oldest first, above
/// the one Tara works on now. Unlike `AskConversation` it keeps the whole answer with its
/// sources, and every turn, for as long as the chat is open.
public struct AskThread: Equatable, Sendable {
    public struct Turn: Equatable, Sendable, Identifiable {
        public var id: Int
        public var question: String
        /// Nil when the question failed.
        public var answer: AskAnswer?
        public var failure: String?
    }

    public private(set) var turns: [Turn] = []
    private var nextID = 0

    public init() {}

    /// The turn on screen before the next question replaces it: kept with its answer or its
    /// failure; a question without either (still thinking, or nothing asked) isn't kept.
    public mutating func archive(question: String?, answer: AskAnswer?, failure: String?) {
        guard let question, !question.isEmpty, answer != nil || failure != nil else { return }
        turns.append(Turn(id: nextID, question: question, answer: failure == nil ? answer : nil, failure: failure))
        nextID += 1
    }

    public mutating func clear() { turns = [] }
}

/// One of Ask Tara's earlier chats: its questions and answers, oldest first, with their sources.
public struct AskChat: Codable, Equatable, Sendable, Identifiable {
    public struct Turn: Codable, Equatable, Sendable {
        public var question: String
        public var answer: AskAnswer

        public init(question: String, answer: AskAnswer) {
            self.question = question
            self.answer = answer
        }
    }

    public var id: String
    public var started: Date
    public var turns: [Turn]

    public init(id: String = UUID().uuidString, started: Date = Date(), turns: [Turn] = []) {
        self.id = id
        self.started = started
        self.turns = turns
    }

    /// Its first question, on one line.
    public var title: String {
        (turns.first?.question ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Ask Tara's earlier chats, kept on this Mac (`ask-chats.json`, readable by the user only), so the
/// bubble can go back to one and carry on. Newest first, at most `limit`.
public struct AskHistory: Sendable {
    public static let limit = 50
    public let file: URL

    public init(file: URL) {
        self.file = file
    }

    public func load() -> [AskChat] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([AskChat].self, from: data)) ?? []
    }

    /// Keeps `chat` (replacing the one with its id) at the top.
    @discardableResult
    public func save(_ chat: AskChat) -> [AskChat] {
        guard !chat.turns.isEmpty else { return load() }
        var chats = load().filter { $0.id != chat.id }
        chats.insert(chat, at: 0)
        write(Array(chats.prefix(Self.limit)))
        return chats
    }

    @discardableResult
    public func delete(_ id: String) -> [AskChat] {
        let chats = load().filter { $0.id != id }
        write(chats)
        return chats
    }

    private func write(_ chats: [AskChat]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(chats) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

/// A file dropped on Tara to ask about: its name and the text read from it (the file itself
/// stays where it is, untouched).
public struct AskDocument: Equatable, Sendable {
    public var name: String
    public var text: String

    public init(name: String, text: String) {
        self.name = name
        self.text = text
    }
}

/// A question about one day (the Timeline's day page): the agent reads only that day's meetings,
/// captures and notes, and `context` brings what the app counted that day besides.
public struct AskScope: Equatable, Sendable {
    /// "2026-10-24".
    public var day: String
    public var context: String

    public init(day: String, context: String = "") {
        self.day = day
        self.context = context
    }
}

/// The `ask` line for `agent.py`, newline included.
public enum AskCommand {
    public static func ask(_ question: String, conversation: AskConversation = AskConversation(),
                           image: String? = nil, document: AskDocument? = nil, scope: AskScope? = nil,
                           screen: [ScreenAskItem] = [], now: Date = Date(), id: String) -> Data {
        Data((text(question, conversation: conversation, image: image, document: document, scope: scope, screen: screen,
                   now: now, id: id) + "\n").utf8)
    }

    /// The same line as text, without the newline (sorted keys, so it reads the same every time).
    public static func text(_ question: String, conversation: AskConversation = AskConversation(),
                            image: String? = nil, document: AskDocument? = nil, scope: AskScope? = nil,
                            screen: [ScreenAskItem] = [], now: Date = Date(), id: String) -> String {
        var object: [String: Any] = ["cmd": "ask", "question": question, "id": id]
        if !conversation.turns.isEmpty {
            object["history"] = conversation.turns.map { ["question": $0.question, "answer": $0.answer] }
        }
        if let image { object["image"] = image }
        if let document { object["document"] = ["name": document.name, "text": document.text] }
        if let scope {
            object["day"] = scope.day
            if !scope.context.isEmpty { object["context"] = scope.context }
        }
        // Recent screen context the app picked for this question (only while that source is on).
        if !screen.isEmpty { object["screen"] = screen.map { $0.json(now: now) } }
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

/// Whether Apple's on-device model can think for Tara: the bundled helper's `--status` line (Sources/AppleModel).
public enum AppleModelStatus: Equatable, Sendable {
    case ready
    /// Apple Intelligence is off in System Settings.
    case notEnabled
    /// On, but the model isn't on this Mac yet.
    case downloading
    /// Not on this Mac (no Apple silicon, or older than macOS 26).
    case notSupported
    /// Unavailable for another reason Apple gives.
    case unavailable
    /// No helper in this build, or no answer it could read.
    case unknown

    public init(statusLine data: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            self = .unknown
            return
        }
        if object["available"] as? Bool == true {
            self = .ready
            return
        }
        switch object["reason"] as? String {
        case "appleIntelligenceNotEnabled": self = .notEnabled
        case "modelNotReady": self = .downloading
        case "deviceNotEligible": self = .notSupported
        case "noHelper": self = .unknown
        default: self = .unavailable
        }
    }
}

/// One piece of recent screen context that goes with a question, cited as "Screen · App · time".
public struct ScreenAskItem: Equatable, Sendable {
    public var id: String
    public var app: String
    public var time: Date
    public var title: String
    public var text: String

    public init(id: String, app: String, time: Date, title: String, text: String) {
        self.id = id
        self.app = app
        self.time = time
        self.title = title
        self.text = text
    }

    /// "Screen · Mail · 14:05" (with the day when it isn't today).
    public func label(now: Date, calendar: Calendar = .current, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = calendar.isDate(time, inSameDayAs: now) ? "HH:mm" : "yyyy-MM-dd HH:mm"
        return "Screen · \(app) · \(formatter.string(from: time))"
    }

    /// As the `screen` field of the `ask` command sends it.
    public func json(now: Date, calendar: Calendar = .current, timeZone: TimeZone = .current) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        iso.timeZone = timeZone
        return ["id": id, "app": app, "time": iso.string(from: time), "title": title, "text": text,
                "label": label(now: now, calendar: calendar, timeZone: timeZone)]
    }
}
