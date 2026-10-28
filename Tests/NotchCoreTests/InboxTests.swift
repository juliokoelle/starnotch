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
        // Blocking first, prompts and questions together, oldest first (they time out); then failed
        // loops; then finished turns, newest first.
        #expect(InboxQueue().pending(entries).map(\.id) == ["approval-old", "question", "approval-new", "loop", "done-new", "done-old"])
    }

    @Test func aBlockedSessionWaitsWithThePrompts() {
        // Blocked in the Claude app: it blocks an agent, so it's worked by age among the prompts.
        let blocked = InboxEntry(id: "blocked", kind: .blocked, at: UTC.date("2026-10-28 09:15"))
        #expect(Array(InboxQueue().pending(entries + [blocked]).map(\.id).prefix(4)) == ["approval-old", "question", "blocked", "approval-new"])
        #expect(blocked.blocks)
    }

    @Test func anArrivalDoesNotPreemptTheFront() {
        var queue = InboxQueue()
        let now = UTC.date("2026-10-28 10:00")
        let done = [entries[0]]
        queue.startRound()
        queue.settle(done, now: now)
        #expect(queue.front == "done-old")
        // A prompt arrives: it ranks first, but queues behind the card on screen.
        let arrived = done + [entries[1]]
        queue.settle(arrived, now: now.addingTimeInterval(1))
        #expect(queue.queue(arrived).map(\.id) == ["done-old", "approval-new"])
        #expect(queue.accepts(now: now.addingTimeInterval(1)))
        // The user moves on: the prompt is next, and keys act on it right away.
        queue.skip(done[0])
        queue.settle(arrived, now: now.addingTimeInterval(2))
        #expect(queue.front == "approval-new")
        #expect(queue.accepts(now: now.addingTimeInterval(2)))
    }

    @Test func keysWaitAfterTheFrontChangesByItself() {
        var queue = InboxQueue()
        let now = UTC.date("2026-10-28 10:00")
        queue.startRound()
        queue.settle(entries, now: now)
        #expect(queue.front == "approval-old")
        // Answered in the terminal: the next one takes the front, and a key in that moment was
        // meant for the card that left.
        let rest = entries.filter { $0.id != "approval-old" }
        queue.settle(rest, now: now.addingTimeInterval(5))
        #expect(queue.front == "question")
        #expect(!queue.accepts(now: now.addingTimeInterval(5.2)))
        #expect(queue.accepts(now: now.addingTimeInterval(5.5)))
    }

    @Test func skippingABlockingItemKeepsItPending() {
        var queue = InboxQueue()
        let first = queue.queue(entries)[0]
        queue.skip(first)
        #expect(queue.queue(entries).first?.id == "question")
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
