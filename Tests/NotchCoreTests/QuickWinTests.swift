import Testing
import TestSupport
@testable import NotchCore

@Suite struct QuickWinTests {
    @Test func paceHitsTheLimitBeforeTheReset() {
        let now = UTC.date("2026-10-24 12:00")
        // 40 % to 60 % in 40 minutes: 0.5 % a minute, 100 % in 80 minutes, at 13:20.
        let samples = [(at: UTC.date("2026-10-24 11:20"), used: 40.0), (at: UTC.date("2026-10-24 11:40"), used: 50.0), (at: now, used: 60.0)]
        #expect(PaceForecast.forecast(samples: samples, resetsAt: UTC.date("2026-10-24 15:00"), now: now) == .hitsLimit(at: UTC.date("2026-10-24 13:20")))
        // The reset comes first.
        #expect(PaceForecast.forecast(samples: samples, resetsAt: UTC.date("2026-10-24 13:00"), now: now) == .lasts(until: UTC.date("2026-10-24 13:00")))
        #expect(PaceForecast.forecast(samples: [(at: now, used: 60)], resetsAt: nil, now: now) == .unknown)
        #expect(PaceForecast.sentence(.hitsLimit(at: now), window: "5 h", clock: { _ in "14:20" }) == "At this pace you hit the 5 h limit at 14:20")
        #expect(PaceForecast.sentence(.lasts(until: now), window: "5 h", clock: { _ in "16:00" }) == "Lasts until the reset at 16:00")
    }

    @Test func alertThresholds() {
        #expect(PaceForecast.crossed(previous: 70, current: 81) == 80)
        #expect(PaceForecast.crossed(previous: 85, current: 91) == 90)
        #expect(PaceForecast.crossed(previous: 70, current: 95) == 90)
        #expect(PaceForecast.crossed(previous: 82, current: 85) == nil)
        #expect(PaceForecast.crossed(previous: nil, current: 50) == nil)
    }

    @Test func battery() throws {
        let charging = try #require(BatteryState.parse(["Type": "InternalBattery", "Current Capacity": 64, "Max Capacity": 100,
                                                        "Is Charging": true, "Power Source State": "AC Power", "Time to Full Charge": 70]))
        #expect(charging.line == "64 % · charging, full in 1 h 10")
        let low = try #require(BatteryState.parse(["Type": "InternalBattery", "Current Capacity": 9, "Max Capacity": 100,
                                                   "Is Charging": false, "Power Source State": "Battery Power", "Time to Empty": -1]))
        #expect(low.isLow)
        #expect(low.line == "9 %")
        #expect(BatteryState.parse(["Type": "UPS"]) == nil)
    }

    @Test func eventFromCapture() throws {
        let calendar = UTC.calendar
        let now = UTC.date("2026-10-24 09:00")
        let parse = CaptureParser.parse("Call Ada tomorrow at 15:00", now: now, calendar: calendar)
        #expect(UTC.string(parse.eventStart(calendar: calendar)) == "2026-10-25 15:00")
        #expect(CaptureParser.title(removingDatesFrom: "Call Ada tomorrow at 15:00") == "Call Ada")
        #expect(CaptureParser.title(removingDatesFrom: "Zahnarzt am Freitag um 9") == "Zahnarzt")
        #expect(CaptureParser.title(removingDatesFrom: "Review 24.10. 16:30 Uhr mit Grace") == "Review mit Grace")
        #expect(CaptureParser.parse("Buy milk", now: now, calendar: calendar).eventStart(calendar: calendar) == nil)
    }

    @Test func shellRecords() throws {
        let running = try #require(ShellActivity.running(file: "run-4242", text: "1792800000\n/Users/ada/app\nnpm run build\n"))
        #expect(running.pid == 4242)
        #expect(running.command == "npm run build")
        #expect(ShellActivity.running(file: "run-4242", text: "") == nil)
        let done = try #require(ShellActivity.finished(text: "1792800134 134 0\n/Users/ada/app\nnpm run build\n"))
        #expect(ShellActivity.line(done) == "finished · 2 m 14 s")
        let failed = try #require(ShellActivity.finished(text: "1792800041 41 2\n/x\nmake test"))
        #expect(ShellActivity.line(failed) == "failed · exit 2 · 41 s")
        #expect(ShellActivity.snippet(folder: "/tmp/a b").contains("typeset -g __starnotch_dir='/tmp/a b'"))
    }
}
