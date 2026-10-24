import Foundation

/// A known person (from a connector's `PeopleProvider`), matched in quick capture text.
public struct Person: Equatable, Sendable, Hashable {
    public var slug: String
    public var name: String

    public init(slug: String, name: String) {
        self.slug = slug
        self.name = name
    }

    public var firstName: String { name.split(separator: " ").first.map(String.init) ?? name }
}

/// What quick capture reads from the text while the user types (Todoist-style): a due date, a
/// time, and people. German and English.
public struct CaptureParse: Equatable, Sendable {
    /// Day of the due date (start of day in the parser's calendar).
    public var day: Date?
    public var hour: Int?
    public var minute: Int?
    public var people: [Person] = []

    public init(day: Date? = nil, hour: Int? = nil, minute: Int? = nil, people: [Person] = []) {
        self.day = day
        self.hour = hour
        self.minute = minute
        self.people = people
    }

    public var hasTime: Bool { hour != nil }

    /// `YYYY-MM-DD` or `YYYY-MM-DD HH:MM`, the capture's due field.
    public func dueField(calendar: Calendar) -> String? {
        guard let day else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        var text = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        if let hour { text += String(format: " %02d:%02d", hour, minute ?? 0) }
        return text
    }
}

public enum CaptureParser {
    static let weekdays = ["sonntag": 1, "montag": 2, "dienstag": 3, "mittwoch": 4, "donnerstag": 5, "freitag": 6, "samstag": 7,
                           "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7]

    public static func parse(_ text: String, now: Date, calendar: Calendar, people: [Person] = []) -> CaptureParse {
        let lower = text.lowercased()
        let today = calendar.startOfDay(for: now)
        func add(_ days: Int) -> Date { calendar.date(byAdding: .day, value: days, to: today)! }

        var result = CaptureParse()

        // Relative days.
        if lower.contains("übermorgen") || lower.contains("day after tomorrow") {
            result.day = add(2)
        } else if lower.firstMatch(of: #/\btomorrow\b/#) != nil {
            result.day = add(1)
        } else if lower.matches(of: #/\bmorgen\b/#).contains(where: { match in
            // "am Morgen" / "guten Morgen" is a time of day, not tomorrow.
            let before = lower[..<match.range.lowerBound].split(separator: " ").last.map(String.init) ?? ""
            return before != "am" && before != "guten" && before != "jeden"
        }) {
            result.day = add(1)
        } else if lower.firstMatch(of: #/\b(heute|today|tonight)\b/#) != nil {
            result.day = today
        }

        // Weekdays: "Freitag", "am Freitag", "bis Freitag", "nächsten Freitag".
        if result.day == nil, let match = lower.firstMatch(of: #/(nächsten |nächste |kommenden |next )?\b(montag|dienstag|mittwoch|donnerstag|freitag|samstag|sonntag|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b/#) {
            let target = weekdays[String(match.output.2)]!
            let current = calendar.component(.weekday, from: today)
            var delta = (target - current + 7) % 7
            if match.output.1 != nil { delta += delta == 0 ? 7 : 7 }
            result.day = add(delta)
        } else if result.day == nil, lower.firstMatch(of: #/\b(nächste woche|next week)\b/#) != nil {
            let current = calendar.component(.weekday, from: today)
            result.day = add((2 - current + 7) % 7 == 0 ? 7 : (2 - current + 7) % 7)
        }

        // Dates: 24.10. / 24.10.2026 / 3.11
        if result.day == nil, let match = lower.firstMatch(of: #/\b(\d{1,2})\.(\d{1,2})\.(\d{4})?(?!\d)/#) {
            let d = Int(match.output.1)!, m = Int(match.output.2)!
            var year = match.output.3.flatMap { Int($0) } ?? calendar.component(.year, from: today)
            if (1...31).contains(d), (1...12).contains(m) {
                var date = calendar.date(from: DateComponents(year: year, month: m, day: d))
                if match.output.3 == nil, let candidate = date, candidate < today {
                    year += 1
                    date = calendar.date(from: DateComponents(year: year, month: m, day: d))
                }
                result.day = date
            }
        }

        // Times: 16:30, 16.30 Uhr, 16 Uhr, um 9.
        if let match = lower.firstMatch(of: #/\b([01]?\d|2[0-3])[:.]([0-5]\d)\s*(uhr)?\b/#),
           match.output.3 != nil || lower[match.range].contains(":") {
            result.hour = Int(match.output.1)
            result.minute = Int(match.output.2)
        } else if let match = lower.firstMatch(of: #/\b([01]?\d|2[0-3])\s*uhr\b/#) {
            result.hour = Int(match.output.1)
            result.minute = 0
        } else if let match = lower.firstMatch(of: #/\b(1[0-2]|0?[1-9])(?::([0-5]\d))?\s*(am|pm)\b/#) {
            let hour = Int(match.output.1)! % 12
            result.hour = match.output.3 == "pm" ? hour + 12 : hour
            result.minute = match.output.2.flatMap { Int($0) } ?? 0
        } else if let match = lower.firstMatch(of: #/\b(um|at) ([01]?\d|2[0-3])\b(?![.:]\d)/#) {
            result.hour = Int(match.output.2)
            result.minute = 0
        }
        if result.hour != nil, result.day == nil {
            // A time alone means today, or tomorrow when it has passed.
            let at = calendar.date(bySettingHour: result.hour!, minute: result.minute ?? 0, second: 0, of: today)!
            result.day = at > now ? today : add(1)
        }

        result.people = match(people: people, in: text)
        return result
    }

    /// Full names always count; a first name only when no other person shares it.
    public static func match(people: [Person], in text: String) -> [Person] {
        let lower = text.lowercased()
        var firstNameCount: [String: Int] = [:]
        for person in people { firstNameCount[person.firstName.lowercased(), default: 0] += 1 }
        func contains(_ word: String) -> Bool {
            guard word.count >= 3, let regex = try? Regex("\\b" + NSRegularExpression.escapedPattern(for: word.lowercased()) + "\\b") else { return false }
            return lower.firstMatch(of: regex) != nil
        }
        var found: [Person] = []
        for person in people {
            let full = contains(person.name)
            let first = firstNameCount[person.firstName.lowercased()] == 1 && contains(person.firstName)
            if (full || first) && !found.contains(person) { found.append(person) }
        }
        return found
    }
}
