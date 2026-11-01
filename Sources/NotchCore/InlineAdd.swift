import Foundation

/// The reminder typed into Today's "+": a title and an optional due day and time. The text is read
/// as quick capture reads it ("Call Ada tomorrow 15:00"); the day chip sets the day by hand.
public struct ReminderDraft: Equatable, Sendable {
    public private(set) var text = ""
    /// Start of the due day; nil without a due date.
    public private(set) var day: Date?
    public private(set) var hour: Int?
    public private(set) var minute: Int?
    /// What the text said last; it counts again only when it says something new, so a day picked
    /// with the chip stays while the title is typed on.
    private var heard: CaptureParse?

    public init() {}

    public mutating func update(text: String, now: Date, calendar: Calendar) {
        self.text = text
        let parse = CaptureParser.parse(text, now: now, calendar: calendar)
        guard parse != heard else { return }
        let before = heard
        heard = parse
        if let named = parse.day {
            day = named
            hour = parse.hour
            minute = parse.minute
        } else if before?.day != nil {
            // The date words were deleted: so is the date they gave.
            day = nil
            hour = nil
            minute = nil
        }
    }

    /// The chip: no date → today → tomorrow → next Monday → no date. A time stays with the day.
    public mutating func cycleDay(now: Date, calendar: Calendar) {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let weekday = calendar.component(.weekday, from: today)
        let toMonday = (2 - weekday + 7) % 7
        let nextWeek = calendar.date(byAdding: .day, value: toMonday == 0 ? 7 : toMonday, to: today) ?? today
        switch day {
        case nil: day = today
        case today: day = tomorrow
        case tomorrow: day = nextWeek
        default:
            day = nil
            hour = nil
            minute = nil
        }
    }

    /// The text without its date words; the whole text when nothing else is left.
    public var title: String {
        let stripped = CaptureParser.title(removingDatesFrom: text)
        return stripped.isEmpty ? text.trimmingCharacters(in: .whitespacesAndNewlines) : stripped
    }

    public var canSave: Bool { !title.isEmpty }

    /// Days from today to the due day ("today" is 0); nil without one.
    public func dayOffset(now: Date, calendar: Calendar) -> Int? {
        guard let day else { return nil }
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: day).day
    }

    /// The due date as Reminders keeps it: the day, with the time when there is one.
    public func due(calendar: Calendar) -> DateComponents? {
        guard let day else { return nil }
        var parts = calendar.dateComponents([.year, .month, .day], from: day)
        if let hour {
            parts.hour = hour
            parts.minute = minute ?? 0
        }
        return parts
    }
}

/// The event typed into the calendar's "+": a title, when it starts and how long it lasts. The text
/// is read like quick capture's ("Lunch with Ada tomorrow 13:00 1h"): a day, a time or a length in
/// it set those; the chips change them by hand. Whatever was done last counts.
public struct EventDraft: Equatable, Sendable {
    public private(set) var text = ""
    public private(set) var start: Date
    public private(set) var minutes: Int
    private var heard: CaptureParse?
    private var heardLength: Int?

    /// The lengths the chip steps through.
    public static let lengths = [15, 30, 45, 60, 90, 120]

    /// An event on `day`: today at the next half hour, another day at 09:00.
    public init(day: Date, now: Date, calendar: Calendar, minutes: Int = 60) {
        self.minutes = minutes
        let shown = calendar.startOfDay(for: day)
        guard calendar.isDate(shown, inSameDayAs: now) else {
            start = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: shown) ?? shown
            return
        }
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let next = (minute / 30 + 1) * 30
        // Late in the evening the next half hour is tomorrow: the last one of today instead.
        let at = next < 24 * 60 ? next : minute / 30 * 30
        start = calendar.date(bySettingHour: at / 60, minute: at % 60, second: 0, of: shown) ?? now
    }

    public var end: Date { start.addingTimeInterval(Double(minutes) * 60) }

    public mutating func update(text: String, now: Date, calendar: Calendar) {
        self.text = text
        let parse = CaptureParser.parse(text, now: now, calendar: calendar)
        if parse != heard {
            heard = parse
            if parse.day != nil || parse.hour != nil {
                // A time alone stays on the day on show; only a named day moves the event.
                let day = parse.dayIsImplied ? calendar.startOfDay(for: start) : parse.day ?? calendar.startOfDay(for: start)
                let parts = calendar.dateComponents([.hour, .minute], from: start)
                let hour = parse.hour ?? parts.hour ?? 9
                let minute = parse.hour != nil ? parse.minute ?? 0 : parts.minute ?? 0
                start = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? start
            }
        }
        let length = Self.length(in: text)
        if length != heardLength {
            heardLength = length
            if let length { minutes = length }
        }
    }

    /// The day chip's arrows.
    public mutating func shift(days: Int, calendar: Calendar) {
        start = calendar.date(byAdding: .day, value: days, to: start) ?? start
    }

    /// The time chip's arrows, in quarter hours; the event stays on its day.
    public mutating func shift(minutes delta: Int, calendar: Calendar) {
        let moved = start.addingTimeInterval(Double(delta) * 60)
        if calendar.isDate(moved, inSameDayAs: start) { start = moved }
    }

    /// The length chip: the next of `lengths`, round again after the last.
    public mutating func nextLength() {
        minutes = Self.lengths.first { $0 > minutes } ?? Self.lengths[0]
    }

    /// The text without its date, time and length words; the whole text when nothing else is left.
    public var title: String {
        var text = self.text
        for pattern in Self.lengthPatterns {
            text = text.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        let stripped = CaptureParser.title(removingDatesFrom: text)
        return stripped.isEmpty ? self.text.trimmingCharacters(in: .whitespacesAndNewlines) : stripped
    }

    public var canSave: Bool { !title.isEmpty }

    static let lengthPatterns = [#"\b(\d{1,3})\s*(min|mins|minutes|minuten|m)\b"#,
                                 #"\b(\d{1,2})([.,]5)?\s*(h|hr|hrs|hour|hours|std|stunde|stunden)\b"#]

    /// "30 min", "45m", "2h", "1,5 Std" in the text, in minutes (5 min to 12 h).
    static func length(in text: String) -> Int? {
        let lower = text.lowercased()
        if let match = lower.firstMatch(of: #/\b(\d{1,3})\s*(min|mins|minutes|minuten|m)\b/#),
           let value = Int(match.output.1), (5...720).contains(value) {
            return value
        }
        if let match = lower.firstMatch(of: #/\b(\d{1,2})([.,]5)?\s*(h|hr|hrs|hour|hours|std|stunde|stunden)\b/#),
           let hours = Int(match.output.1) {
            let value = hours * 60 + (match.output.2 == nil ? 0 : 30)
            return (5...720).contains(value) ? value : nil
        }
        return nil
    }
}
