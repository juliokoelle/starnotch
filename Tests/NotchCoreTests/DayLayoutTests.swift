import Testing
@testable import NotchCore

@Suite struct DayLayoutTests {
    // A Saturday: routine, a day-long event with a talk and practice on top, a run, dinner.
    let day: [(start: Double, end: Double)] = [(450, 540), (570, 1080), (570, 630), (600, 660), (1110, 1155), (1200, 1320)]

    @Test func overlappingEventsStackIntoLanes() {
        let lanes = DayLayout.lanes(day)
        #expect(lanes == [0, 0, 1, 2, 0, 0])
        // Back to back is not an overlap.
        #expect(DayLayout.lanes([(600, 660), (660, 720)]) == [0, 0])
        #expect(DayLayout.lanes([]) == [])
    }

    @Test func hoursStretchToTheDay() {
        #expect(DayLayout.hours(day) == (420, 1320))  // 07–22: the routine starts at 07:30
        #expect(DayLayout.hours([]) == (480, 1320))
        #expect(DayLayout.hours([(600, 1400)]) == (480, 1440))
    }

    @Test func freeTimeCountsEveryEvent() {
        // At 08:00 the day isn't "14 h free": the routine runs until 09:00, the event from 09:30.
        let gaps = DayLayout.free(day, from: 480, to: 1320, minimum: 30)
        #expect(gaps == [DayGaps.Gap(start: 540, end: 570), DayGaps.Gap(start: 1080, end: 1110), DayGaps.Gap(start: 1155, end: 1200)])
    }

    @Test func statusLine() {
        let events = [(title: "Routine", start: 450.0, end: 540.0), (title: "Hackathon", start: 570.0, end: 1080.0)]
        #expect(DayLayout.status(events, now: 480) == "Routine until 09:00")
        #expect(DayLayout.status(events, now: 545) == "free until 09:30")
        #expect(DayLayout.status(events, now: 1100) == "free for the rest of the day")
    }
}
