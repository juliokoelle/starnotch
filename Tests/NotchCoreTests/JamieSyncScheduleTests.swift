import Foundation
import Testing
@testable import NotchCore

/// When Jamie syncs on its own: launch, every half hour, wake, after meetings, Ask Tara, backoff.
@Suite struct JamieSyncScheduleTests {
    let launch = Date(timeIntervalSince1970: 1_800_000_000)

    func minutes(_ value: Double) -> Date { launch.addingTimeInterval(value * 60) }

    @Test func nothingWithoutALogin() {
        let schedule = JamieSyncSchedule(connected: false, launched: launch)
        #expect(schedule.nextSync == nil)
        #expect(!schedule.shouldSync(.timer, now: minutes(600)))
        #expect(!schedule.shouldSync(.askOpened, now: minutes(600)))
    }

    @Test func shortlyAfterLaunchThenEveryHalfHour() {
        var schedule = JamieSyncSchedule(connected: true, launched: launch, lastSuccess: minutes(-5))
        #expect(schedule.nextSync == launch.addingTimeInterval(20))  // also when the last run synced a moment ago
        #expect(!schedule.shouldSync(.timer, now: launch.addingTimeInterval(10)))
        #expect(schedule.shouldSync(.timer, now: launch.addingTimeInterval(30)))
        schedule.succeeded(at: minutes(1))
        #expect(schedule.nextSync == minutes(31))
        #expect(!schedule.shouldSync(.timer, now: minutes(30)))
        #expect(schedule.shouldSync(.timer, now: minutes(31)))
    }

    @Test func aWakeSyncsOnlyAnOldSync() {
        var schedule = JamieSyncSchedule(connected: true, launched: launch)
        schedule.succeeded(at: minutes(1))
        #expect(!schedule.shouldSync(.wake, now: minutes(11)))
        #expect(schedule.shouldSync(.wake, now: minutes(41)))
    }

    @Test func fiveAndTwentyMinutesAfterAMeetingEnds() {
        var schedule = JamieSyncSchedule(connected: true, launched: launch, meetingEnds: [minutes(15)])
        schedule.succeeded(at: minutes(1))
        #expect(schedule.nextSync == minutes(20))
        #expect(!schedule.shouldSync(.timer, now: minutes(19)))
        #expect(schedule.shouldSync(.timer, now: minutes(20)))
        schedule.succeeded(at: minutes(21))
        #expect(schedule.nextSync == minutes(35))  // the second look, before the half hour
        schedule.succeeded(at: minutes(36))
        #expect(schedule.nextSync == minutes(66))  // both done: back to every half hour
    }

    @Test func aMeetingStillRunningWaitsForItsEnd() {
        var schedule = JamieSyncSchedule(connected: true, launched: launch, meetingEnds: [minutes(120)])
        schedule.succeeded(at: minutes(1))
        #expect(schedule.nextSync == minutes(31))
        schedule.succeeded(at: minutes(110))
        #expect(schedule.nextSync == minutes(125))
    }

    @Test func askTaraSyncsInTheBackgroundWhenTheLastSyncIsOlderThanTenMinutes() {
        var schedule = JamieSyncSchedule(connected: true, launched: launch)
        schedule.succeeded(at: minutes(1))
        #expect(!schedule.shouldSync(.askOpened, now: minutes(9)))
        #expect(schedule.shouldSync(.askOpened, now: minutes(12)))
        #expect(!schedule.shouldSync(.timer, now: minutes(12)))  // only Ask Tara opening, not the timer
    }

    @Test func failuresBackOffFiveFifteenThenSixtyMinutes() {
        var schedule = JamieSyncSchedule(connected: true, launched: launch)
        schedule.failed(at: minutes(1))
        #expect(schedule.nextSync == minutes(6))
        schedule.failed(at: minutes(6))
        #expect(schedule.nextSync == minutes(21))
        schedule.failed(at: minutes(21))
        #expect(schedule.nextSync == minutes(81))
        schedule.failed(at: minutes(81))
        #expect(schedule.nextSync == minutes(141))  // it stays at an hour
        #expect(!schedule.shouldSync(.askOpened, now: minutes(100)))  // Ask Tara waits out the backoff too
        #expect(!schedule.shouldSync(.wake, now: minutes(100)))
        #expect(schedule.shouldSync(.askOpened, now: minutes(141)))
        schedule.succeeded(at: minutes(142))
        #expect(schedule.failures == 0)
        #expect(schedule.nextSync == minutes(172))
    }

    @Test func aBackoffHoldsBackTheMeetingFollowUp() {
        var schedule = JamieSyncSchedule(connected: true, launched: launch, meetingEnds: [minutes(0)])
        schedule.failed(at: minutes(5))
        #expect(!schedule.shouldSync(.timer, now: minutes(9)))
        #expect(schedule.shouldSync(.timer, now: minutes(10)))
    }
}
