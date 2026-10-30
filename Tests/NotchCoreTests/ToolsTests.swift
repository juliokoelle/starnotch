import Foundation
import Testing
import TestSupport
@testable import NotchCore

@Suite struct ToolsTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func clipboardKeepsNewestOnceAndPinnedOnTop() {
        var history = ClipboardHistory()
        let added = history.add("first", at: t0)
        let blank = history.add("   \n", at: t0)
        #expect(added && !blank)
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

    @Test func clipboardKeepsImagesWithinTheirLimit() {
        var history = ClipboardHistory()
        let png = Data([1, 2, 3])
        let added = history.addImage(png, thumbnail: nil, width: 40, height: 30, at: t0)
        #expect(added)
        history.add("text", at: t0 + 1)
        history.addImage(png, thumbnail: nil, width: 40, height: 30, at: t0 + 2)
        #expect(history.items.count == 2 && history.items[0].isImage && history.items[0].pixelWidth == 40)
        let tooLarge = history.addImage(Data(count: ClipboardHistory.maxImageBytes + 1), thumbnail: nil, width: 1, height: 1, at: t0)
        #expect(!tooLarge)
        let pinned = history.items[0].id
        history.togglePin(pinned)
        for index in 0..<(ClipboardHistory.imageLimit + 3) {
            history.addImage(Data([UInt8(index), 9]), thumbnail: nil, width: 1, height: 1, at: t0 + 10 + Double(index))
        }
        #expect(history.items.filter { $0.isImage && !$0.pinned }.count == ClipboardHistory.imageLimit)
        #expect(history.items.contains { $0.id == pinned })
        #expect(history.items.contains { $0.text == "text" })
    }

    @Test func clipboardImagesStayWithinTheirMemoryBudget() {
        var history = ClipboardHistory()
        let size = ClipboardHistory.maxImageBytes
        // Eleven large images: within the count, beyond the budget; the oldest unpinned go.
        for index in 0..<11 {
            history.addImage(Data(repeating: UInt8(index), count: size), thumbnail: nil, width: 1, height: 1, at: t0 + Double(index))
        }
        #expect(history.imageBytes() <= ClipboardHistory.imageBudget)
        #expect(history.items.count == ClipboardHistory.imageBudget / size)
        #expect(history.items.last?.image?.first == UInt8(11 - history.items.count))
        // Pins stop where a new copy would no longer fit beside them.
        var pinned = 0
        for item in history.items where history.togglePin(item.id) { pinned += 1 }
        #expect(pinned == ClipboardHistory.pinnedImageBudget / size)
        #expect(history.imageBytes(pinned: true) <= ClipboardHistory.pinnedImageBudget)
        // A new image still fits; an unpinned one makes way for it, a pinned one never does.
        history.addImage(Data(repeating: 99, count: size), thumbnail: nil, width: 1, height: 1, at: t0 + 20)
        #expect(history.items.first?.image?.first == 99)
        #expect(history.items.filter(\.pinned).count == pinned)
        #expect(history.imageBytes() <= ClipboardHistory.imageBudget)
        // Unpinning always works; text pins aren't limited.
        let unpinned = history.togglePin(history.items.first { $0.pinned }!.id)
        history.add("note", at: t0 + 30)
        let textPinned = history.togglePin(history.items[0].id)
        #expect(unpinned && textPinned)
    }

    @Test func clipboardChecksAnImageBeforeDecodingIt() {
        #expect(ClipboardHistory.acceptsImage(bytes: 1_000, width: 2560, height: 1600))
        #expect(!ClipboardHistory.acceptsImage(bytes: ClipboardHistory.maxImageInputBytes + 1, width: 10, height: 10))
        #expect(!ClipboardHistory.acceptsImage(bytes: 1_000, width: 10_000, height: 10_000))
        #expect(!ClipboardHistory.acceptsImage(bytes: 1_000, width: 0, height: 10))
        #expect(!ClipboardHistory.acceptsImage(bytes: 0, width: 10, height: 10))
    }

    @Test func clipLinkLeadsWithTheDomain() {
        let link = ClipItem(text: "https://www.example.com/a/b?c=1", copied: t0).link
        #expect(link?.domain == "example.com" && link?.rest == "/a/b?c=1")
        #expect(ClipItem(text: " https://example.org/ ", copied: t0).link?.rest == "")
        #expect(ClipItem(text: "see https://example.com", copied: t0).link == nil)
        #expect(ClipItem(text: "mailto:me@example.com", copied: t0).link == nil)
        #expect(ClipboardHistory(items: [ClipItem(text: "a", copied: t0, source: "Safari")]).list(matching: "safari").count == 1)
    }

    @Test func countdownShortFitsTheEar() {
        #expect(Countdown.short(45) == "45s")
        #expect(Countdown.short(12 * 60 + 35) == "12m")
        #expect(Countdown.short(2 * 3600 + 5) == "2h")
        #expect(Countdown.short(3600 + 59 * 60 + 59) == "1h59")
        #expect(Countdown.short(3600 + 4 * 60) == "1h04")
        #expect(Countdown.short(11 * 3600 + 30 * 60) == "11h")
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
        let early = timer.tick(at: t0 + 60)
        let ended = timer.tick(at: t0 + 25 * 60)
        #expect(early == nil && ended == .focus)
        #expect(timer.phase == .shortBreak && timer.doneToday == 1)
        // Three more rounds: the fourth focus is followed by the long break.
        var now = t0 + 25 * 60
        for _ in 0..<3 {
            now += 5 * 60
            let breakEnded = timer.tick(at: now)
            now += 25 * 60
            let focusEnded = timer.tick(at: now)
            #expect(breakEnded == .shortBreak && focusEnded == .focus)
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
        let skipped = timer.skip(at: t0 + 1100)
        #expect(skipped == .focus)
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

@Suite struct DeviceBatteryTests {
    @Test func parsesAirPodsAndPrefersTheOutputsName() throws {
        let json = """
        {"SPBluetoothDataType":[{"controller_properties":{},"device_connected":[
          {"Magic Mouse":{"device_batteryLevelMain":"64%"}},
          {"AirPods Pro":{"device_batteryLevelLeft":"80%","device_batteryLevelRight":"78%","device_batteryLevelCase":"52%"}}
        ],"device_not_connected":[{"Old Speaker":{"device_batteryLevelMain":"10%"}}]}]}
        """
        let pods = try #require(DeviceBattery.parse(Data(json.utf8), preferring: "AirPods Pro"))
        #expect(pods.line == "L 80 % · R 78 % · Case 52 %")
        #expect(pods.lowest == 78)
        let any = try #require(DeviceBattery.parse(Data(json.utf8), preferring: "Speakers"))
        #expect(any.name == "Magic Mouse" && any.line == "64 %")
        #expect(DeviceBattery.parse(Data("{}".utf8), preferring: nil) == nil)
    }
}

@Suite struct SimpleTimerTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func countdownPausesAndEnds() {
        var timer = SimpleTimer()
        timer.duration = 300
        timer.start(at: t0)
        timer.pause(at: t0 + 100)
        #expect(timer.isActive && !timer.isRunning && timer.remaining(at: t0 + 999) == 200)
        timer.start(at: t0 + 1000)
        let early = timer.tick(at: t0 + 1100)
        let done = timer.tick(at: t0 + 1200)
        #expect(!early && done && !timer.isActive)
    }

    @Test func stopwatchCountsUp() {
        var timer = SimpleTimer()
        timer.mode = .stopwatch
        timer.start(at: t0)
        let ended = timer.tick(at: t0 + 10_000)
        #expect(!ended && timer.shown(at: t0 + 90) == 90 && timer.progress(at: t0 + 90) == 0.5)
    }
}

@Suite struct DeviceNameTests {
    @Test func outputAndDeviceNamesMatchLoosely() {
        #expect(DeviceBattery.sameDevice("Max's AirPods Pro", "AirPods Pro"))
        #expect(DeviceBattery.sameDevice("Magic Mouse", nil))
        #expect(!DeviceBattery.sameDevice("Magic Mouse", "AirPods Pro"))
    }
}
