import Testing
import TestSupport
@testable import NotchCore

/// Plan limits as a time: when a window runs out at the current pace.
@Suite struct PaceProjectionTests {
    @Test func averageSinceTheWindowOpenedBeforeThereAreSamples() {
        // The 5-hour window opened at 10:00 (reset 15:00). At 12:00, 60 % used: 30 % an hour,
        // 100 % at 13:20.
        let now = UTC.date("2026-10-24 12:00")
        let reset = UTC.date("2026-10-24 15:00")
        #expect(PaceForecast.projection(usedPercent: 60, minutes: 300, resetsAt: reset, now: now) == .hitsLimit(at: UTC.date("2026-10-24 13:20")))
        // 20 % in two hours lasts until the reset.
        #expect(PaceForecast.projection(usedPercent: 20, minutes: 300, resetsAt: reset, now: now) == .lasts(until: reset))
        // Too early (10 minutes into the window) or too little used: no guess.
        #expect(PaceForecast.projection(usedPercent: 30, minutes: 300, resetsAt: UTC.date("2026-10-24 16:50"), now: now) == .unknown)
        #expect(PaceForecast.projection(usedPercent: 1, minutes: 300, resetsAt: reset, now: now) == .unknown)
        // Full already.
        #expect(PaceForecast.projection(usedPercent: 100, minutes: 300, resetsAt: reset, now: now) == .hitsLimit(at: now))
        // No window length or reset: no guess.
        #expect(PaceForecast.projection(usedPercent: 60, minutes: nil, resetsAt: reset, now: now) == .unknown)
    }

    @Test func recentSamplesWinOverTheAverage() {
        let now = UTC.date("2026-10-24 12:00")
        // Slow on average (30 % in two hours lasts) but 10 % in the last 20 minutes: 70 % left at 0.5 % a minute, full at 14:20.
        let samples = [(at: UTC.date("2026-10-24 11:40"), used: 20.0), (at: now, used: 30.0)]
        #expect(PaceForecast.projection(usedPercent: 30, minutes: 300, resetsAt: UTC.date("2026-10-24 15:00"), samples: samples, now: now)
                == .hitsLimit(at: UTC.date("2026-10-24 14:20")))
    }
}
