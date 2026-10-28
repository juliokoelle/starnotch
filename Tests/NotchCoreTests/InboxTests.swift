import Testing
import TestSupport
@testable import NotchCore

@Suite struct InboxTests {
    let entries = [
        InboxEntry(id: "done-old", kind: .done, at: UTC.date("2026-10-28 09:00")),
        InboxEntry(id: "approval-new", kind: .approval, at: UTC.date("2026-10-28 09:20")),
        InboxEntry(id: "loop", kind: .failedLoop, at: UTC.date("2026-10-28 06:00")),
        InboxEntry(id: "done-new", kind: .done, at: UTC.date("2026-10-28 09:30")),
        InboxEntry(id: "question", kind: .question, at: UTC.date("2026-10-28 09:10")),
        InboxEntry(id: "approval-old", kind: .approval, at: UTC.date("2026-10-28 09:05")),
    ]

    @Test func order() {
        // Blocking first, oldest first (they time out); then failed loops; then finished turns, newest first.
        #expect(InboxQueue().pending(entries).map(\.id) == ["approval-old", "approval-new", "question", "loop", "done-new", "done-old"])
    }

    @Test func skippingABlockingItemKeepsItPending() {
        var queue = InboxQueue()
        let first = queue.queue(entries)[0]
        queue.skip(first)
        #expect(queue.queue(entries).first?.id == "approval-new")
        // Still waiting on the user: it counts, and it's back next round.
        #expect(queue.count(entries) == 6)
        queue.startRound()
        #expect(queue.queue(entries).first?.id == "approval-old")
    }

    @Test func skippingANoticeDismissesIt() {
        var queue = InboxQueue()
        let loop = entries.first { $0.id == "loop" }!
        queue.skip(loop)
        #expect(queue.count(entries) == 5)
        queue.startRound()
        #expect(!queue.queue(entries).contains { $0.id == "loop" })
    }

    @Test func handledItemsLeave() {
        var queue = InboxQueue()
        queue.skip(entries.first { $0.id == "question" }!)
        queue.dismiss("question")
        queue.dismiss("done-new")
        #expect(queue.pending(entries).map(\.id) == ["approval-old", "approval-new", "loop", "done-old"])
        #expect(queue.skipped.isEmpty)
    }

    @Test func aNewTurnComesBack() {
        // A finished turn's id carries the turn; once dismissed, the next turn of the session is new.
        var queue = InboxQueue()
        queue.dismiss("done:a@100")
        let next = [InboxEntry(id: "done:a@200", kind: .done, at: UTC.date("2026-10-28 10:00"))]
        #expect(queue.count(next) == 1)
        queue.forget(keeping: next)
        #expect(queue.dismissed.isEmpty)
    }

    @Test func emptyInbox() {
        let queue = InboxQueue()
        #expect(queue.queue([]).isEmpty)
        #expect(queue.count([]) == 0)
    }
}
