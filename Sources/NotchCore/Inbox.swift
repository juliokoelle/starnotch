import Foundation

/// One thing in the agents inbox: something an agent or a loop needs from the user.
public struct InboxEntry: Equatable, Sendable, Identifiable {
    public enum Kind: Int, Sendable {
        /// A permission prompt (Claude Code, Codex): the agent is blocked until it's answered.
        case approval
        /// A question through the MCP server, with options or free text.
        case question
        /// A loop failed today.
        case failedLoop
        /// A session finished its turn: the user's move.
        case done
        /// A session blocked where the notch can't answer (the Claude app says it needs action):
        /// only its own window can.
        case blocked
    }

    /// Stable for as long as the thing it stands for is the same (a new turn gets a new id).
    public var id: String
    public var kind: Kind
    public var at: Date

    public init(id: String, kind: Kind, at: Date) {
        self.id = id
        self.kind = kind
        self.at = at
    }

    /// An agent waits on the answer; skipping it leaves it waiting.
    public var blocks: Bool { kind == .approval || kind == .question || kind == .blocked }

    /// The order to work through: what blocks an agent, then failed loops, then finished turns.
    var rank: Int { blocks ? 0 : kind == .failedLoop ? 1 : 2 }
}

/// The order of the inbox and what the user set aside: skipped blocking items come back next
/// round, skipped notices (done, failed) are gone for good.
public struct InboxQueue: Equatable, Sendable {
    public private(set) var dismissed: Set<String> = []
    public private(set) var skipped: Set<String> = []
    /// The item on screen: it stays in front until the user moves on or it goes away, so an
    /// arrival queues behind it instead of taking the keys meant for the card the user read.
    public private(set) var front: String?
    /// When the front changed without the user moving on (answered elsewhere, timed out, or the
    /// first arrival into an empty inbox): keys wait `settleDelay` after that.
    public private(set) var frontChanged: Date?
    /// The user moved on (a key, a click, a new round): the next front is theirs to see.
    private var advanced = false

    public static let settleDelay: TimeInterval = 0.4

    public init() {}

    /// Everything that needs the user, in the order to work through: what blocks an agent
    /// first (oldest first, it times out, prompts and questions alike), then failed loops, then
    /// finished turns (newest first).
    public func pending(_ entries: [InboxEntry]) -> [InboxEntry] {
        entries.filter { !dismissed.contains($0.id) }.sorted { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            if a.at != b.at { return a.blocks ? a.at < b.at : a.at > b.at }
            return a.id < b.id
        }
    }

    /// What this round still shows: pending, minus what was skipped in it, the front first.
    public func queue(_ entries: [InboxEntry]) -> [InboxEntry] {
        var items = pending(entries).filter { !skipped.contains($0.id) }
        if let front, let index = items.firstIndex(where: { $0.id == front }), index > 0 {
            items.insert(items.remove(at: index), at: 0)
        }
        return items
    }

    /// The number in the ear: everything pending, skipped or not.
    public func count(_ entries: [InboxEntry]) -> Int { pending(entries).count }

    /// Pins what is in front now. Call it when the entries change and before every key.
    public mutating func settle(_ entries: [InboxEntry], now: Date) {
        let first = queue(entries).first?.id
        if first != front {
            front = first
            frontChanged = advanced || first == nil ? nil : now
        }
        advanced = false
    }

    /// Whether a key may act on the front: not in the moment after it changed by itself.
    public func accepts(now: Date) -> Bool {
        frontChanged.map { now.timeIntervalSince($0) >= Self.settleDelay } ?? true
    }

    /// Esc: on to the next. A blocking item stays pending (and in the count); a notice is done.
    public mutating func skip(_ entry: InboxEntry) {
        if entry.blocks { skipped.insert(entry.id) } else { dismissed.insert(entry.id) }
        moveOn(from: entry.id)
    }

    /// Handled (answered, opened): out of the inbox.
    public mutating func dismiss(_ id: String) {
        dismissed.insert(id)
        skipped.remove(id)
        moveOn(from: id)
    }

    /// The inbox opens again: what was skipped last time is back.
    public mutating func startRound() {
        skipped.removeAll()
        front = nil
        frontChanged = nil
        advanced = true
    }

    /// Drops remembered ids that no longer occur, so the sets stay small.
    public mutating func forget(keeping entries: [InboxEntry]) {
        let ids = Set(entries.map(\.id))
        dismissed.formIntersection(ids)
        skipped.formIntersection(ids)
    }

    private mutating func moveOn(from id: String) {
        guard id == front else { return }
        front = nil
        advanced = true
    }
}
