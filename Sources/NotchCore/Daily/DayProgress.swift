import Foundation

/// The work day, from `start` to `end` (minutes after midnight). An end at or before the start
/// runs past midnight (a night shift). Weekends are off unless they count.
public struct WorkDay: Codable, Equatable, Sendable {
    public var start: Int
    public var end: Int
    public var weekends: Bool

    public init(start: Int = 9 * 60, end: Int = 18 * 60, weekends: Bool = false) {
        self.start = start
        self.end = end
        self.weekends = weekends
    }

    public enum Phase: Equatable, Sendable {
        /// A weekend that doesn't count.
        case off
        case before
        /// `done` of the day is behind, 0 to 1.
        case during(done: Double)
        case after
    }

    /// Length in minutes (a night shift wraps past midnight).
    public var length: Int { end > start ? end - start : end + 24 * 60 - start }

    public func phase(at now: Date, calendar: Calendar = .current) -> Phase {
        let minute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        let exact = Double(minute) + Double(calendar.component(.second, from: now)) / 60
        let overnight = end <= start
        // Past midnight in a night shift, the day that counts is the one it began on.
        let shiftDay = overnight && minute < end ? calendar.date(byAdding: .day, value: -1, to: now) ?? now : now
        if !weekends && calendar.isDateInWeekend(shiftDay) { return .off }
        let elapsed: Double
        if overnight {
            if minute >= start { elapsed = exact - Double(start) }
            else if minute < end { elapsed = exact + Double(24 * 60 - start) }
            else { return .before }  // between shifts: the next one starts tonight
        } else {
            if minute < start { return .before }
            if minute >= end { return .after }
            elapsed = exact - Double(start)
        }
        return .during(done: min(1, max(0, elapsed / Double(max(1, length)))))
    }

    /// 0 before the day, 1 after it.
    public func progress(at now: Date, calendar: Calendar = .current) -> Double {
        switch phase(at: now, calendar: calendar) {
        case .off, .before: 0
        case .during(let done): done
        case .after: 1
        }
    }

    /// Minutes left in a running day, else nil.
    public func minutesLeft(at now: Date, calendar: Calendar = .current) -> Int? {
        guard case .during(let done) = phase(at: now, calendar: calendar) else { return nil }
        return Int((Double(length) * (1 - done)).rounded(.up))
    }

    /// "09:00" for a minute of the day.
    public static func clock(_ minutes: Int) -> String {
        let wrapped = ((minutes % (24 * 60)) + 24 * 60) % (24 * 60)
        return String(format: "%02d:%02d", wrapped / 60, wrapped % 60)
    }

    /// "3 h 10 min", "45 min".
    public static func duration(_ minutes: Int) -> String {
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(rest) min" }
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }
}
