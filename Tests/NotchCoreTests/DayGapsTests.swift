import Testing
@testable import NotchCore

@Suite struct DayGapsTests {
    @Test func gapsIgnoreShortBreaks() {
        let busy: [(start: Double, end: Double)] = [(750, 780), (960, 990), (1110, 1200)]
        let gaps = DayGaps.free(busy: busy, from: 480, to: 1320, minimum: 30)
        #expect(gaps.map(\.start) == [480, 780, 990, 1200])
        #expect(DayGaps.label(gaps[1]) == "free until 16:00")
        #expect(DayGaps.duration(90) == "1 h 30")
        #expect(DayGaps.duration(45) == "45 min")
    }
}
