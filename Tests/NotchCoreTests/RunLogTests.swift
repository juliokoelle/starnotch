import Foundation
import Testing
import TestSupport
@testable import NotchCore

@Suite struct RunLogTests {
    @Test func parsesLinesAndSkipsProse() {
        let text = """
        # Loop-RUNLOG
        > Eine Zeile pro Lauf: `YYYY-MM-DD · <loop> · ok|degraded|skip|fail · <Kurznotiz>`
        2026-10-25 · morning-brief · ok · built for 26.10.
        2026-10-26 · capture-processor · degraded · one file unclear · flagged
        2026-10-26 · morning brief · ok · a loop name with a space is no loop
        """
        let runs = RunLog.parse(text)
        #expect(runs.map(\.loop) == ["morning-brief", "capture-processor"])
        #expect(runs[1].status == .degraded && runs[1].note == "one file unclear · flagged")
    }

    @Test func cronFromTheFrontMatter() {
        let spec = """
        ---
        loop: morning-brief
        trigger: "täglich 04:30, cron 30 4,12,20 * * *, Cloud-Routine"
        ---
        # Loop: Morning Brief, cron 0 0 * * * in the body doesn't count
        """
        let schedules = RunLog.schedules(inFrontMatter: spec)
        #expect(schedules.map(\.expression) == ["30 4,12,20 * * *"])
    }

    @Test func otherWaysToWriteTheSchedule() {
        func expressions(_ trigger: String) -> [String] {
            RunLog.schedules(inFrontMatter: "---\ntrigger: \"\(trigger)\"\n---\n").map(\.expression)
        }
        #expect(expressions("sonntags 05:00 UTC (0 5 * * 0), Cloud-Routine") == ["0 5 * * 0"])
        #expect(expressions("täglich 03:30 UTC, Cloud-Routine. Läuft vor Job Research (04:00 UTC)") == ["30 3 * * *"])
        #expect(expressions("täglich 05:00 UTC (07:00 Berlin, solange CEST gilt)") == ["0 5 * * *"])
        #expect(expressions("whenever Julio feels like it").isEmpty)
    }

    @Test func lateWhenScheduledAndSilent() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 15)))
        let today = RunLog.day(now), old = RunLog.day(now.addingTimeInterval(-3 * 86_400))
        let runs = [LoopRun(day: today, loop: "capture-processor", status: .ok, note: ""),
                    LoopRun(day: old, loop: "morning-brief", status: .ok, note: "")]
        let cron = try #require(CronSchedule("30 4 * * *"))
        let specs = ["morning-brief": RunLog.Spec(url: URL(fileURLWithPath: "/tmp/morning-brief.md"), schedules: [cron])]
        let loops = RunLog.loops(runs: runs, specs: specs, now: now)
        #expect(loops.map(\.name) == ["capture-processor", "morning-brief"])
        #expect(loops[1].isLate && !loops[0].isLate)
        #expect(loops[1].specURL?.lastPathComponent == "morning-brief.md")
        #expect(loops[1].nextRun != nil && loops[0].nextRun == nil)
    }
}
