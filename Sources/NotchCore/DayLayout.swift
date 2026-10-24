import Foundation

/// Layout of a day's events on a time band: overlapping events go into lanes, the visible hours
/// stretch to the day's first and last event, and free time counts everything on the calendar.
public enum DayLayout {
    /// The lane of each interval (in input order): an event goes into the first lane where the
    /// previous event has ended; overlapping events stack. Minutes since midnight.
    public static func lanes(_ intervals: [(start: Double, end: Double)]) -> [Int] {
        let order = intervals.indices.sorted {
            intervals[$0].start != intervals[$1].start ? intervals[$0].start < intervals[$1].start
                : intervals[$0].end - intervals[$0].start > intervals[$1].end - intervals[$1].start
        }
        var laneEnds: [Double] = []
        var result = Array(repeating: 0, count: intervals.count)
        for index in order {
            let interval = intervals[index]
            if let lane = laneEnds.firstIndex(where: { $0 <= interval.start }) {
                laneEnds[lane] = interval.end
                result[index] = lane
            } else {
                laneEnds.append(interval.end)
                result[index] = laneEnds.count - 1
            }
        }
        return result
    }

    /// Whole hours shown: 08–22 at least, widened to the first start and last end.
    public static func hours(_ intervals: [(start: Double, end: Double)]) -> (from: Double, to: Double) {
        let first = intervals.map(\.start).min() ?? 8 * 60
        let last = intervals.map(\.end).max() ?? 22 * 60
        let from = min(8.0, (first / 60).rounded(.down)), to = max(22.0, (last / 60).rounded(.up))
        return (max(0, from) * 60, min(24, to) * 60)
    }

    /// Free stretches from `from` to `to` (minutes) that no event covers, at least `minimum` long.
    public static func free(_ intervals: [(start: Double, end: Double)], from: Double, to: Double, minimum: Double = 30) -> [DayGaps.Gap] {
        DayGaps.free(busy: intervals, from: from, to: to, minimum: minimum)
    }

    /// One line for where the day stands at `now`: "free until 09:30", "free for the rest of the
    /// day", "Opening talk until 10:30", or "nothing left today".
    public static func status(_ events: [(title: String, start: Double, end: Double)], now: Double, dayEnd: Double = 24 * 60) -> String {
        let current = events.filter { $0.start <= now && $0.end > now }.min { $0.end < $1.end }
        if let current { return "\(current.title) until \(DayGaps.clock(current.end))" }
        let next = events.filter { $0.start > now }.min { $0.start < $1.start }
        if let next { return "free until \(DayGaps.clock(next.start))" }
        return events.isEmpty || now < dayEnd ? "free for the rest of the day" : "nothing left today"
    }
}
