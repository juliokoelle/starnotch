import Testing
import TestSupport
@testable import NotchCore

@Suite struct QuotaTests {
    @Test func usageLineFields() {
        let line = #"{"parentUuid":"x","type":"assistant","timestamp":"2026-10-21T08:35:30.989Z","message":{"id":"msg_011CgF5N","role":"assistant","usage":{"input_tokens":2,"cache_creation_input_tokens":100,"cache_read_input_tokens":17271,"output_tokens":684}}}"#
        let usage = UsageLine.parse(Substring(line))
        #expect(usage?.messageID == "msg_011CgF5N")
        #expect(usage?.tokens == 786)
        #expect(UTC.string(usage?.date) == "2026-10-21 08:35")
        #expect(UsageLine.parse(#"{"type":"user","message":{"content":"usage"}}"#) == nil)
    }

    @Test func fiveHourBlockAgainstPeak() throws {
        // Yesterday a block of 1000, today a block that started 09:00 with 600 so far.
        let data = UTC.hourly([("2026-10-20 10:00", 400), ("2026-10-20 12:00", 600),
                           ("2026-10-21 09:00", 300), ("2026-10-21 10:00", 300)])
        let estimate = try #require(QuotaEstimator.estimate(hourly: data, now: UTC.date("2026-10-21 10:30"), calendar: UTC.calendar))
        #expect(estimate.window == QuotaEstimate.Window.fiveHours)
        #expect(estimate.used == 0.6)
        #expect(UTC.string(estimate.resets) == "2026-10-21 14:00")
        // 60 % used after 30 % of the block: too fast.
        #expect(estimate.pace == QuotaEstimate.Pace.tight)
        #expect(estimate.weekUsed == nil)   // not a week of history yet
        #expect(estimate.blockTokens == 600)
        #expect(estimate.weekTokens == 1600)
        #expect(QuotaEstimator.tokens(1_234_000) == "1.2 M")
        #expect(QuotaEstimator.tokens(84_000) == "84 k")
        #expect(QuotaEstimator.tokens(530) == "530")
    }

    @Test func calmPaceAndNoCurrentBlock() throws {
        let data = UTC.hourly([("2026-10-20 10:00", 1000), ("2026-10-21 06:00", 100)])
        let calm = try #require(QuotaEstimator.estimate(hourly: data, now: UTC.date("2026-10-21 10:00"), calendar: UTC.calendar))
        #expect(calm.pace == QuotaEstimate.Pace.enough)
        #expect(calm.used == 0.1)
        let none = try #require(QuotaEstimator.estimate(hourly: data, now: UTC.date("2026-10-21 12:00"), calendar: UTC.calendar))
        #expect(none.fiveHourUsed == 0)
        #expect(none.resets == nil)
        #expect(QuotaEstimator.estimate(hourly: UTC.hourly([]), now: UTC.date("2026-10-21 12:00")) == nil)
    }

    @Test func weekWinsWhenCloser() throws {
        var entries: [(String, Int)] = []
        // Two weeks ago a heavy week, this week lighter but the current block small.
        for day in 1...7 { entries.append((String(format: "2026-10-%02d 10:00", day), 1000)) }
        for day in 15...20 { entries.append((String(format: "2026-10-%02d 10:00", day), 1000)) }
        entries.append(("2026-10-21 09:00", 100))
        let estimate = try #require(QuotaEstimator.estimate(hourly: UTC.hourly(entries), now: UTC.date("2026-10-21 09:30"), calendar: UTC.calendar))
        #expect(estimate.window == QuotaEstimate.Window.week)
        #expect(estimate.weekUsed! > 0.85)
        #expect(QuotaEstimator.level(0.62) == QuotaEstimator.Level.calm)
        #expect(QuotaEstimator.level(0.85) == QuotaEstimator.Level.warn)
        #expect(QuotaEstimator.level(0.93) == QuotaEstimator.Level.critical)
    }
}
