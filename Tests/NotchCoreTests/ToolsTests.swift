import Foundation
import Testing
import TestSupport
@testable import NotchCore

@Suite struct ToolsTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func clipboardKeepsNewestOnceAndPinnedOnTop() {
        var history = ClipboardHistory()
        #expect(history.add("first", at: t0))
        #expect(!history.add("   \n", at: t0))
        history.add("second", at: t0 + 1)
        history.add("first", at: t0 + 2)
        #expect(history.list().map(\.text) == ["first", "second"])
        let second = history.list()[1].id
        history.togglePin(second)
        #expect(history.list().map(\.text) == ["second", "first"])
        history.clear()
        #expect(history.list().map(\.text) == ["second"])
    }

    @Test func clipboardSearchAndLimit() {
        var history = ClipboardHistory()
        for index in 0..<(ClipboardHistory.limit + 5) { history.add("item \(index)", at: t0 + Double(index)) }
        #expect(history.items.count == ClipboardHistory.limit)
        #expect(history.list(matching: "ITEM 204").map(\.text) == ["item 204"])
        #expect(history.list(matching: "item 0").isEmpty)
    }

    @Test func clipboardSkipsSecrets() {
        #expect(ClipboardHistory.shouldSkip(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"], app: nil))
        #expect(ClipboardHistory.shouldSkip(types: ["public.utf8-plain-text"], app: "com.1password.1password"))
        #expect(!ClipboardHistory.shouldSkip(types: ["public.utf8-plain-text"], app: "com.apple.Safari"))
    }

    @Test func clipLineFoldsWhitespace() {
        let item = ClipItem(text: "a\n\n  b\tc", copied: t0)
        #expect(item.line() == "a b c")
        #expect(ClipItem(text: String(repeating: "x", count: 100), copied: t0).line(10) == "xxxxxxxxx…")
    }

    @Test func focusChainsIntoBreaksAndCountsRounds() {
        var timer = FocusTimer()
        timer.start(at: t0)
        #expect(timer.phase == .focus && timer.remaining(at: t0) == 25 * 60)
        #expect(timer.tick(at: t0 + 60) == nil)
        #expect(timer.tick(at: t0 + 25 * 60) == .focus)
        #expect(timer.phase == .shortBreak && timer.doneToday == 1)
        // Three more rounds: the fourth focus is followed by the long break.
        var now = t0 + 25 * 60
        for _ in 0..<3 {
            now += 5 * 60
            #expect(timer.tick(at: now) == .shortBreak)
            now += 25 * 60
            #expect(timer.tick(at: now) == .focus)
        }
        #expect(timer.phase == .longBreak && timer.round == 4)
    }

    @Test func focusPausesAndSkips() {
        var timer = FocusTimer()
        timer.start(at: t0)
        timer.pause(at: t0 + 600)
        #expect(timer.isPaused && timer.remaining(at: t0 + 5000) == 15 * 60)
        timer.start(at: t0 + 1000)
        #expect(timer.remaining(at: t0 + 1000) == 15 * 60)
        #expect(timer.skip(at: t0 + 1100) == .focus)
        #expect(timer.phase == .shortBreak && timer.doneToday == 0)  // skipped focus doesn't count
        timer.stop()
        #expect(timer.phase == .idle && !timer.isRunning)
    }

    @Test func countdownText() {
        #expect(Countdown.text(25 * 60) == "25:00")
        #expect(Countdown.text(59.2) == "1:00")
        #expect(Countdown.text(3723) == "1:02:03")
    }
}
