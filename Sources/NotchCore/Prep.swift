import Foundation

// Meeting prep and the free time of a day: value types a connector fills, plus pure helpers.

/// A person with one line of context, for meeting prep (from a connector's `PeopleProvider`).
public struct PersonNote: Equatable, Sendable {
    public var slug: String
    public var name: String
    public var role: String
    public var company: String
    public var connection: String
    /// Newest row of the `## Interactions` table: date as written and a short note.
    public var lastContact: (day: String, note: String)?

    public init(slug: String, name: String, role: String = "", company: String = "", connection: String = "",
                lastContact: (day: String, note: String)? = nil) {
        self.slug = slug
        self.name = name
        self.role = role
        self.company = company
        self.connection = connection
        self.lastContact = lastContact
    }

    public static func == (lhs: PersonNote, rhs: PersonNote) -> Bool {
        lhs.slug == rhs.slug && lhs.name == rhs.name && lhs.role == rhs.role && lhs.company == rhs.company
            && lhs.connection == rhs.connection && lhs.lastContact?.day == rhs.lastContact?.day
            && lhs.lastContact?.note == rhs.lastContact?.note
    }

    public var firstName: String { name.split(separator: " ").first.map(String.init) ?? name }

    /// "Ada Lovelace" -> "AL".
    public var initials: String {
        String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
    }

    /// The one line the notch shows: role and company, else how the user knows the person.
    public var summary: String {
        let role = Self.clause(role), company = Self.clause(company)
        var parts = role.isEmpty ? [] : [role]
        if !company.isEmpty, !role.localizedCaseInsensitiveContains(company) { parts.append(company) }
        return parts.isEmpty ? Self.clause(connection) : parts.joined(separator: " · ")
    }

    /// Text up to the first bracket, comma or full stop.
    public static func clause(_ text: String) -> String {
        let cut = text.prefix { !"(,;.".contains($0) }
        return cut.trimmingCharacters(in: .whitespaces)
    }
}

/// What the notch shows before a meeting: the people, and what is open with them.
public struct MeetingPrep: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public enum Source: String, Sendable { case task, waiting }
        public var source: Source
        public var title: String
        public var detail: String
        /// Due date of a task or follow-up date of a waiting item (`YYYY-MM-DD`).
        public var date: String?
        /// Whose name or company matched.
        public var person: String

        public init(source: Source, title: String, detail: String = "", date: String? = nil, person: String = "") {
            self.source = source
            self.title = title
            self.detail = detail
            self.date = date
            self.person = person
        }
    }

    /// Attendees with a person note, in attendee order.
    public var people: [PersonNote]
    /// Attendees without a note (shown by name only).
    public var unknown: [String]
    public var items: [Item]

    public init(people: [PersonNote] = [], unknown: [String] = [], items: [Item] = []) {
        self.people = people
        self.unknown = unknown
        self.items = items
    }
}

/// Free time between meetings, in minutes since midnight. Focus blocks don't count as busy.
public enum DayGaps {
    public struct Gap: Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var minutes: Double { end - start }

        public init(start: Double, end: Double) {
            self.start = start
            self.end = end
        }
    }

    public static func free(busy: [(start: Double, end: Double)], from: Double, to: Double,
                            minimum: Double = 30) -> [Gap] {
        var gaps: [Gap] = []
        var cursor = from
        for block in busy.sorted(by: { $0.start < $1.start }) {
            if block.start - cursor >= minimum { gaps.append(Gap(start: cursor, end: min(block.start, to))) }
            cursor = max(cursor, block.end)
            if cursor >= to { break }
        }
        if to - cursor >= minimum { gaps.append(Gap(start: cursor, end: to)) }
        return gaps
    }

    /// "free until 16:00".
    public static func label(_ gap: Gap) -> String {
        "free until \(clock(gap.end))"
    }

    /// "1 h 30", "45 min".
    public static func duration(_ minutes: Double) -> String {
        let m = Int(minutes.rounded())
        if m < 60 { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60)"
    }

    public static func clock(_ minutes: Double) -> String {
        let m = Int(minutes.rounded())
        let h = m / 60, rest = m % 60
        return (h < 10 ? "0" : "") + "\(h):" + (rest < 10 ? "0" : "") + "\(rest)"
    }
}
