import Testing
import TestSupport
@testable import NotchCore

@Suite struct AppCostTests {
    private func counters(start: UInt64 = 7, cpu: UInt64, wakeups: UInt64 = 0) -> AppCost.Counters {
        AppCost.Counters(start: start, cpuNanoseconds: cpu, wakeups: wakeups, footprint: 0)
    }

    @Test func rateBetweenTwoReadings() {
        let rate = AppCost.rate(from: counters(cpu: 1_000_000_000, wakeups: 100), to: counters(cpu: 1_040_000_000, wakeups: 140), seconds: 2)
        #expect(rate == AppCost.Rate(cpu: 0.02, wakeupsPerSecond: 20))
    }

    @Test func noRateWithoutAnEarlierReadingOfTheSameProcess() {
        #expect(AppCost.rate(from: nil, to: counters(cpu: 5), seconds: 2) == nil)
        // The pid now belongs to another process.
        #expect(AppCost.rate(from: counters(start: 1, cpu: 900), to: counters(start: 2, cpu: 5), seconds: 2) == nil)
        #expect(AppCost.rate(from: counters(cpu: 900), to: counters(cpu: 5), seconds: 2) == nil)
        #expect(AppCost.rate(from: counters(cpu: 5), to: counters(cpu: 5), seconds: 0) == nil)
    }

    @Test func restLogKeepsTheSharesOfTheLastDay() {
        var log = RestLog()
        let start = UTC.date("2026-10-28 00:00")
        log.record(cpuNanoseconds: 0, at: start)
        #expect(log.points.isEmpty)  // one reading is no share yet
        log.record(cpuNanoseconds: 3_000_000_000, at: start.addingTimeInterval(300))  // 3 s in 5 min: 1 %
        log.record(cpuNanoseconds: 9_000_000_000, at: start.addingTimeInterval(600))  // 6 s: 2 %
        #expect(log.points.map(\.cpu) == [0.01, 0.02])
        #expect(abs(log.average(since: start)! - 0.015) < 1e-12)
        #expect(log.average(since: start.addingTimeInterval(601)) == nil)
        // A day later the first points have gone.
        log.record(cpuNanoseconds: 9_300_000_000, at: start.addingTimeInterval(RestLog.window + 400))
        log.record(cpuNanoseconds: 9_600_000_000, at: start.addingTimeInterval(RestLog.window + 700))
        #expect(log.points.count == 1 && abs(log.points[0].cpu - 0.001) < 1e-12)
    }

    @Test func restLogSkipsASleep() {
        var log = RestLog()
        let start = UTC.date("2026-10-28 00:00")
        log.record(cpuNanoseconds: 0, at: start)
        log.record(cpuNanoseconds: 1_000_000_000, at: start.addingTimeInterval(3600))  // the Mac slept in between
        #expect(log.points.isEmpty)
        log.record(cpuNanoseconds: 4_000_000_000, at: start.addingTimeInterval(3900))
        #expect(log.points.map(\.cpu) == [0.01])
    }
}
