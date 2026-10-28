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
    public var blocks: Bool { kind == .approval || kind == .question }
}

/// The order of the inbox and what the user set aside: skipped blocking items come back next
/// round, skipped notices (done, failed) are gone for good.
public struct InboxQueue: Equatable, Sendable {
    public private(set) var dismissed: Set<String> = []
    public private(set) var skipped: Set<String> = []

    public init() {}

    /// Everything that needs the user, in the order to work through: what blocks an agent
    /// first (oldest first, it times out), then failed loops, then finished turns (newest first).
    public func pending(_ entries: [InboxEntry]) -> [InboxEntry] {
        entries.filter { !dismissed.contains($0.id) }.sorted { a, b in
            if a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
            if a.at != b.at { return a.blocks ? a.at < b.at : a.at > b.at }
            return a.id < b.id
        }
    }

    /// What this round still shows: pending, minus what was skipped in it.
    public func queue(_ entries: [InboxEntry]) -> [InboxEntry] {
        pending(entries).filter { !skipped.contains($0.id) }
    }

    /// The number in the ear: everything pending, skipped or not.
    public func count(_ entries: [InboxEntry]) -> Int { pending(entries).count }

    /// Esc: on to the next. A blocking item stays pending (and in the count); a notice is done.
    public mutating func skip(_ entry: InboxEntry) {
        if entry.blocks { skipped.insert(entry.id) } else { dismissed.insert(entry.id) }
    }

    /// Handled (answered, opened): out of the inbox.
    public mutating func dismiss(_ id: String) {
        dismissed.insert(id)
        skipped.remove(id)
    }

    /// The inbox opens again: what was skipped last time is back.
    public mutating func startRound() {
        skipped.removeAll()
    }

    /// Drops remembered ids that no longer occur, so the sets stay small.
    public mutating func forget(keeping entries: [InboxEntry]) {
        let ids = Set(entries.map(\.id))
        dismissed.formIntersection(ids)
        skipped.formIntersection(ids)
    }
}
