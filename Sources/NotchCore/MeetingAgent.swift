import Foundation

// The meeting agent's JSON lines (agent/PROTOCOL.md), turned into what the Meeting module shows.

/// One line from `agent.py` or `transcribe.py`. Unknown types and lines that aren't JSON give `nil`.
public enum MeetingLine: Equatable, Sendable {
    case ready(meetings: Int, model: String?)
    /// Something said; `speaker` is `""` when the transcriber has no names.
    case utterance(speaker: String, text: String)
    case card(MeetingCard)
    case status(state: String, message: String?)
    case error(String)
    /// `jamie_sync.py`: one meeting stored, and the end of a sync.
    case synced(title: String)
    case syncDone(meetings: Int)

    public static func parse(_ data: Data) -> MeetingLine? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "ready":
            return .ready(meetings: object["meetings"] as? Int ?? 0, model: string(object["model"]))
        case "utterance":
            guard let text = string(object["text"]) else { return nil }
            return .utterance(speaker: string(object["speaker"]) ?? "", text: text)
        case "status":
            let state = string(object["state"]) ?? ""
            if state == "synced" { return .syncDone(meetings: object["meetings"] as? Int ?? 0) }
            // `login` carries the address the browser was sent to instead of a message.
            return .status(state: state, message: string(object["message"]) ?? string(object["url"]))
        case "synced":
            return .synced(title: string(object["title"]) ?? "")
        case "error":
            return .error(string(object["message"]) ?? "error")
        default:
            return MeetingCard.make(type: type, object).map(MeetingLine.card)
        }
    }

    /// A trimmed, non-empty string, else `nil`.
    static func string(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// An event as a card: a short title and detail for the sneak, and every field the event carries as blocks.
public struct MeetingCard: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case contradiction, question, commitment, answer, prep
    }

    public enum Block: Equatable, Sendable {
        /// Small label above a group ("Earlier", "Open commitments").
        case heading(String)
        case text(String)
        /// A quote with where it came from ("Jonas · Kickoff Lumen-Abo · 2026-10-12"; may be empty).
        case quote(String, source: String)
    }

    public var kind: Kind
    public var title: String
    public var detail: String?
    public var blocks: [Block]

    public init(kind: Kind, title: String, detail: String? = nil, blocks: [Block]) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.blocks = blocks
    }

    static func make(type: String, _ object: [String: Any]) -> MeetingCard? {
        let s = MeetingLine.string
        switch type {
        case "contradiction":
            guard let now = s(object["now"]) else { return nil }
            var blocks: [Block] = []
            if let note = s(object["note"]) { blocks.append(.text(note)) }
            blocks.append(.heading("Just said"))
            blocks.append(.quote(now, source: s(object["speaker"]) ?? ""))
            if let before = object["before"] as? [String: Any], let quote = s(before["quote"]) {
                blocks.append(.heading("Earlier"))
                blocks.append(.quote(quote, source: source(before)))
            }
            return MeetingCard(kind: .contradiction, title: "Contradiction", detail: s(object["note"]) ?? now, blocks: blocks)
        case "question":
            guard let text = s(object["text"]) else { return nil }
            var blocks: [Block] = [.text(text)]
            if let reason = s(object["reason"]) { blocks.append(.quote(reason, source: "")) }
            return MeetingCard(kind: .question, title: "Ask", detail: text, blocks: blocks)
        case "commitment":
            guard let what = s(object["what"]) else { return nil }
            let who = s(object["who"])
            let line = [who, what].compactMap { $0 }.joined(separator: ": ") + due(object["due"], overdue: false)
            var blocks: [Block] = [.text(line)]
            if let quote = s(object["quote"]) { blocks.append(.quote(quote, source: who ?? "")) }
            return MeetingCard(kind: .commitment, title: "Commitment", detail: line, blocks: blocks)
        case "answer":
            guard let text = s(object["text"]) else { return nil }
            var blocks: [Block] = []
            if let question = s(object["question"]) { blocks.append(.heading(question)) }
            blocks.append(.text(text))
            let sources = (object["sources"] as? [[String: Any]] ?? []).compactMap { item in
                s(item["quote"]).map { Block.quote($0, source: source(item)) }
            }
            if sources.isEmpty {
                blocks.append(.quote("Nothing in the memory for this.", source: ""))
            } else {
                blocks.append(.heading("Sources"))
                blocks += sources
            }
            return MeetingCard(kind: .answer, title: "Answer", detail: text, blocks: blocks)
        case "prep":
            return prep(object)
        default:
            return nil
        }
    }

    private static func prep(_ object: [String: Any]) -> MeetingCard {
        let s = MeetingLine.string
        let people = (object["participants"] as? [String] ?? []).joined(separator: ", ")
        var blocks: [Block] = []
        if let last = object["last_meeting"] as? [String: Any] {
            blocks.append(.heading("Last time"))
            blocks.append(.text([s(last["meeting"]), s(last["date"])].compactMap { $0 }.joined(separator: " · ")))
            if let summary = s(last["summary"]) { blocks.append(.quote(summary, source: "")) }
        }
        let decisions = object["decisions"] as? [[String: Any]] ?? []
        if !decisions.isEmpty {
            blocks.append(.heading("Decisions"))
            for item in decisions {
                if let text = s(item["text"]) { blocks.append(.text(text)) }
                if let quote = s(item["quote"]) { blocks.append(.quote(quote, source: source(item))) }
            }
        }
        let open = object["open_commitments"] as? [[String: Any]] ?? []
        if !open.isEmpty {
            blocks.append(.heading("Open commitments"))
            for item in open {
                let overdue = item["overdue"] as? Bool == true
                blocks.append(.text([s(item["who"]), s(item["what"])].compactMap { $0 }.joined(separator: ": ")
                                     + due(item["due"], overdue: overdue)))
                if let quote = s(item["quote"]) { blocks.append(.quote(quote, source: source(item))) }
            }
        }
        let captures = (object["captures"] as? [[String: Any]] ?? []).compactMap { item in
            s(item["text"]).map { Block.text($0 + due(item["due"], overdue: item["overdue"] as? Bool == true)) }
        }
        if !captures.isEmpty {
            blocks.append(.heading("Your notes"))
            blocks += captures
        }
        if blocks.isEmpty { blocks.append(.text("Nothing in the memory about them yet.")) }
        return MeetingCard(kind: .prep, title: "Prep", detail: people.isEmpty ? "all meetings" : people, blocks: blocks)
    }

    /// " (by 2026-10-28)", " (overdue since 2026-10-16)" or "".
    private static func due(_ value: Any?, overdue: Bool) -> String {
        guard let due = MeetingLine.string(value) else { return "" }
        return overdue ? " (overdue since \(due))" : " (by \(due))"
    }

    /// "Jonas · Kickoff Lumen-Abo · 2026-10-12", leaving out what's missing.
    static func source(_ object: [String: Any]) -> String {
        ["speaker", "meeting", "date"].compactMap { MeetingLine.string(object[$0]) }.joined(separator: " · ")
    }
}

/// The JSON lines the app sends to `agent.py`, newline included.
public enum MeetingCommand {
    public static func save(title: String) -> Data { line(["cmd": "save", "title": title]) }
    public static func prep(participants: [String]) -> Data { line(["cmd": "prep", "participants": participants]) }
    /// After `jamie_sync.py` wrote new meetings into the memory folder.
    public static var reload: Data { line(["cmd": "reload"]) }

    private static func line(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        data.append(0x0A)
        return data
    }
}
