import Testing
import TestSupport
@testable import NotchCore

@Suite struct LoopTests {
    @Test func displayNames() {
        #expect(LoopStatus.displayName("morning-brief") == "Morning brief")
        #expect(LoopStatus.displayName("nightly_backup") == "Nightly backup")
        #expect(LoopStatus.displayName("x") == "X")
    }

    @Test func todaysSlots() throws {
        let cron = try #require(CronSchedule("0 3,15 * * *"))
        let entries = [LoopRun(day: "2026-10-21", loop: "nightly-backup", status: .ok, note: "3 files")]
        let slots = LoopTimeline.today(schedules: [cron], entries: entries, dayStart: UTC.date("2026-10-21 00:00"), now: UTC.date("2026-10-21 16:00"))
        #expect(slots.count == 2)
        #expect(slots[0].status == .ok)
        #expect(slots[1].missed)                 // 15:00 passed, no line yet
        let morning = LoopTimeline.today(schedules: [cron], entries: [], dayStart: UTC.date("2026-10-21 00:00"), now: UTC.date("2026-10-21 10:00"))
        #expect(morning[0].missed)
        #expect(morning[1].status == nil && !morning[1].missed)
    }

    @Test func loopPush() throws {
        let push = try StatusPayload.make(fields: ["loop": "morning-brief", "state": "RUNNING"])
        #expect(push.loop == "morning-brief")
        #expect(push.state == "running")
        #expect(push.title == "Morning brief")
        let bad = try StatusPayload.make(fields: ["loop": "x; rm", "state": "exploded", "title": "Hi"])
        #expect(bad.loop == nil && bad.state == nil)
    }
}
