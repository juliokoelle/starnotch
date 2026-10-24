import Testing
import TestSupport
@testable import NotchCore

@Suite struct CronTests {
    @Test func dailyList() throws {
        let cron = try #require(CronSchedule("30 4,12,20 * * *"))
        #expect(UTC.string(cron.next(after: UTC.date("2026-10-20 04:29"))) == "2026-10-20 04:30")
        #expect(UTC.string(cron.next(after: UTC.date("2026-10-20 04:30"))) == "2026-10-20 12:30")
        #expect(UTC.string(cron.next(after: UTC.date("2026-10-20 21:00"))) == "2026-10-21 04:30")
    }

    @Test func rangesStepsAndWeekdays() throws {
        let everyQuarter = try #require(CronSchedule("*/15 9-10 * * *"))
        #expect(UTC.string(everyQuarter.next(after: UTC.date("2026-10-20 09:50"))) == "2026-10-20 10:00")
        #expect(UTC.string(everyQuarter.next(after: UTC.date("2026-10-20 10:45"))) == "2026-10-21 09:00")
        // 2026-10-20 is a Tuesday; Monday runs only.
        let mondays = try #require(CronSchedule("0 8 * * 1"))
        #expect(UTC.string(mondays.next(after: UTC.date("2026-10-20 12:00"))) == "2026-10-26 08:00")
        // Sunday as 7.
        let sundays = try #require(CronSchedule("0 8 * * 7"))
        #expect(UTC.string(sundays.next(after: UTC.date("2026-10-20 12:00"))) == "2026-10-25 08:00")
        // Day of month or weekday.
        let either = try #require(CronSchedule("0 0 1 * 1"))
        #expect(UTC.string(either.next(after: UTC.date("2026-10-27 00:00"))) == "2026-11-01 00:00")
    }

    @Test func rejectsInvalid() {
        #expect(CronSchedule("61 * * * *") == nil)
        #expect(CronSchedule("* * *") == nil)
        #expect(CronSchedule("a b c d e") == nil)
        #expect(CronSchedule("5-1 * * * *") == nil)
    }
}
