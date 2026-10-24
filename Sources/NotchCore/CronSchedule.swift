import Foundation

/// A five-field cron expression (minute hour day-of-month month day-of-week), evaluated in UTC.
/// Supports `*`, lists, ranges and steps. Like cron, a restricted day-of-month and a restricted
/// day-of-week match when either matches.
public struct CronSchedule: Equatable, Sendable {
    public let expression: String
    let minutes: [Int]
    let hours: [Int]
    let days: Set<Int>
    let months: Set<Int>
    let weekdays: Set<Int>
    let daysRestricted: Bool
    let weekdaysRestricted: Bool

    public init?(_ expression: String) {
        let fields = expression.split(separator: " ").map(String.init)
        guard fields.count == 5,
              let minutes = Self.field(fields[0], 0...59),
              let hours = Self.field(fields[1], 0...23),
              let days = Self.field(fields[2], 1...31),
              let months = Self.field(fields[3], 1...12),
              let weekdays = Self.field(fields[4], 0...7) else { return nil }
        self.expression = expression
        self.minutes = minutes.sorted()
        self.hours = hours.sorted()
        self.days = days
        self.months = months
        self.weekdays = Set(weekdays.map { $0 % 7 })
        self.daysRestricted = fields[2] != "*"
        self.weekdaysRestricted = fields[4] != "*"
    }

    /// The first run strictly after `date`.
    public func next(after date: Date) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let startOfDay = calendar.startOfDay(for: date)
        for offset in 0..<400 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startOfDay) else { return nil }
            let parts = calendar.dateComponents([.day, .month, .weekday], from: day)
            guard let dom = parts.day, let month = parts.month, let weekday = parts.weekday,
                  months.contains(month), matchesDay(dom: dom, weekday: weekday - 1) else { continue }
            for hour in hours {
                for minute in minutes {
                    let candidate = day.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
                    if candidate > date { return candidate }
                }
            }
        }
        return nil
    }

    private func matchesDay(dom: Int, weekday: Int) -> Bool {
        switch (daysRestricted, weekdaysRestricted) {
        case (true, true): days.contains(dom) || weekdays.contains(weekday)
        case (true, false): days.contains(dom)
        case (false, true): weekdays.contains(weekday)
        case (false, false): true
        }
    }

    static func field(_ text: String, _ range: ClosedRange<Int>) -> Set<Int>? {
        var values = Set<Int>()
        for part in text.split(separator: ",") {
            let pieces = part.split(separator: "/", maxSplits: 1)
            let step = pieces.count == 2 ? Int(pieces[1]) : 1
            guard let step, step > 0 else { return nil }
            var lower = range.lowerBound, upper = range.upperBound
            let base = pieces[0]
            if base != "*" {
                let bounds = base.split(separator: "-", maxSplits: 1).map { Int($0) }
                guard let first = bounds.first, let low = first else { return nil }
                lower = low
                upper = bounds.count == 2 ? (bounds[1] ?? -1) : (pieces.count == 2 ? range.upperBound : low)
            }
            guard range.contains(lower), range.contains(upper), lower <= upper else { return nil }
            values.formUnion(stride(from: lower, through: upper, by: step))
        }
        return values.isEmpty ? nil : values
    }
}
