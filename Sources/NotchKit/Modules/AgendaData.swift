import AppKit
import NotchCore
import SwiftUI

// Data for the calendar and Today modules: a clock the recordings can shift, events, and the
// sample day used by previews (no calendar permission needed).

/// A shifted clock, so every capture shows the same moment of the day (12:18 by default).
enum R5Clock {
    @MainActor static var offset: TimeInterval = 0

    @MainActor static func now(_ date: Date = Date()) -> Date { date.addingTimeInterval(offset) }

    /// Makes `now()` read `hour:minute` today.
    @MainActor static func set(hour: Int, minute: Int) {
        let real = Date()
        let target = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: real) ?? real
        offset = target.timeIntervalSince(real)
    }

    static func minutes(_ date: Date) -> Double {
        date.timeIntervalSince(Calendar.current.startOfDay(for: date)) / 60
    }

    static func day(_ date: Date) -> String { AgentScanner.day(date) }

    private static let english = Locale(identifier: "en_GB")

    /// "Wednesday, 21 October".
    static func longDay(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(english))
    }

    /// "Wednesday".
    static func weekday(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).locale(english))
    }

    /// "in 12 min", "in 1 h 5 min", "20 min left", "ended".
    static func countdown(start: Date, end: Date, now: Date) -> String {
        if now >= end { return "ended" }
        if now >= start {
            let left = Int((end.timeIntervalSince(now) / 60).rounded(.up))
            return "\(left) min left"
        }
        let minutes = Int((start.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 0 { return "now" }
        if minutes < 60 { return "in \(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "in \(hours) h" : "in \(hours) h \(rest) min"
    }

    /// "today", "tomorrow", "Fri 23.10.", "overdue" for a `YYYY-MM-DD` relative to `today`.
    static func due(_ day: String, today: String) -> String {
        let key = String(day.prefix(10))
        if key < today { return "overdue" }
        if key == today { return "today" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: key), let base = formatter.date(from: today) else { return key }
        let days = Calendar.current.dateComponents([.day], from: base, to: date).day ?? 0
        if days == 1 { return "tomorrow" }
        let short = date.formatted(.dateTime.weekday(.abbreviated).locale(english)).replacingOccurrences(of: ".", with: "")
        return "\(short) \(date.formatted(.dateTime.day(.twoDigits).month(.twoDigits).locale(.init(identifier: "de_DE"))))"
    }

    static func isSoon(_ day: String, today: String) -> Bool {
        let label = due(day, today: today)
        return label == "today" || label == "overdue"
    }
}

/// A calendar as macOS Calendar lists it: its name and colour (an identity, not a status).
struct CalendarSource: Equatable {
    var rawValue: String
    var color: Color

    // Sample calendars for previews.
    static let work = CalendarSource(rawValue: "Work", color: Color(hex: 0x8F76F6))
    static let personal = CalendarSource(rawValue: "Personal", color: Color(hex: 0x45C7B4))
    static let family = CalendarSource(rawValue: "Family", color: Color(hex: 0xF3A23F))
    static let shared = CalendarSource(rawValue: "Shared", color: Color(hex: 0xE674A8))
}

struct CalEvent: Identifiable, Equatable {
    enum Kind { case meeting, focus }

    var id: String
    var title: String
    var start: Date
    var end: Date
    var calendar: CalendarSource
    var kind: Kind
    var attendees: [String] = []
    var link: MeetingLink?
    var location: String?

    var startMinutes: Double { R5Clock.minutes(start) }
    var endMinutes: Double { R5Clock.minutes(end) }

    static func == (lhs: CalEvent, rhs: CalEvent) -> Bool { lhs.id == rhs.id && lhs.start == rhs.start }

    /// From EventKit (via `CalendarModule`): calls and meetings stay meetings, solo blocks without
    /// attendees or link are focus blocks.
    init(_ meeting: CalendarModule.Meeting) {
        self.init(id: meeting.id, title: meeting.title, start: meeting.start, end: meeting.end,
                  calendar: CalendarSource(rawValue: meeting.calendar, color: meeting.color),
                  kind: meeting.kind == .focus ? .focus : .meeting,
                  attendees: meeting.attendees, link: meeting.link, location: meeting.location)
    }

    init(id: String, title: String, start: Date, end: Date, calendar: CalendarSource, kind: Kind,
         attendees: [String] = [], link: MeetingLink? = nil, location: String? = nil) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.calendar = calendar
        self.kind = kind
        self.attendees = attendees
        self.link = link
        self.location = location
    }
}

/// A made-up day for previews and the test mode: focus blocks, a design review, a call.
enum AgendaSamples {
    static func day(_ now: Date = Date()) -> [CalEvent] {
        let start = Calendar.current.startOfDay(for: now)
        func at(_ hour: Double) -> Date { start.addingTimeInterval(hour * 3600) }
        return [
            CalEvent(id: "writing", title: "Writing", start: at(9.5), end: at(11.5), calendar: .personal, kind: .focus),
            CalEvent(id: "review", title: "Design review", start: at(12.5), end: at(13), calendar: .work,
                     kind: .meeting, attendees: ["Ada Lovelace"],
                     link: MeetingLink(provider: .meet, url: URL(string: "https://meet.google.com/abc-defg-hij")!)),
            CalEvent(id: "deep-work", title: "Deep work", start: at(14), end: at(15.5), calendar: .personal, kind: .focus),
            CalEvent(id: "intro", title: "Intro call", start: at(16), end: at(16.5), calendar: .shared,
                     kind: .meeting, attendees: ["Grace Hopper"],
                     link: MeetingLink(provider: .zoom, url: URL(string: "https://zoom.us/j/1234567890")!)),
            CalEvent(id: "planning", title: "Planning with Alan and Ada", start: at(18.5), end: at(19.5), calendar: .work,
                     kind: .meeting, attendees: ["Ada Lovelace", "Alan Turing", "Katherine Johnson"], location: "Room 2"),
            CalEvent(id: "dinner", title: "Family dinner", start: at(20), end: at(21), calendar: .family, kind: .meeting),
        ]
    }

    /// A weekend day without meetings: a long morning routine, a day-long event with a talk on
    /// top of it, sport and dinner. Long titles, overlaps.
    static func saturday(_ now: Date = Date()) -> [CalEvent] {
        let start = Calendar.current.startOfDay(for: now)
        func at(_ hour: Double) -> Date { start.addingTimeInterval(hour * 3600) }
        return [
            CalEvent(id: "routine", title: "Morning routine and journaling", start: at(7.5), end: at(9), calendar: .personal, kind: .focus),
            CalEvent(id: "hack", title: "Agentic AI Hackathon by the community", start: at(9.5), end: at(18), calendar: .shared, kind: .focus,
                     location: "Factory Campus"),
            CalEvent(id: "talk", title: "Opening talk", start: at(9.5), end: at(10.5), calendar: .shared, kind: .focus),
            CalEvent(id: "pitch", title: "Pitch practice", start: at(10), end: at(11), calendar: .personal, kind: .focus),
            CalEvent(id: "run", title: "Run", start: at(18.5), end: at(19.25), calendar: .personal, kind: .focus),
            CalEvent(id: "dinner", title: "Dinner with friends", start: at(20), end: at(22), calendar: .family, kind: .focus),
        ]
    }

    /// Meetings per day this week, Monday first; today is computed from `day()`.
    static let week: [Int] = [3, 2, 0, 2, 3, 0, 1]
    /// What makes a day stand out in the week glance.
    static let weekNotes: [Int: String] = [4: "Launch review"]
}

/// Sample connector for previews and the test mode (`--preview`, `--sample-data`): a Today list
/// and meeting prep with made-up people. Shows what a connector provides without any setup.
final class SampleConnector: NotchConnector, TodayProvider, PeopleProvider, @unchecked Sendable {
    static let id = "sample"
    static let displayName = "Sample data"
    var confirmations = true

    init(config: ConfigSection) {}
    convenience init() { self.init(config: ConfigSection()) }

    static let people = [
        PersonNote(slug: "ada-lovelace", name: "Ada Lovelace", role: "Engineering lead", company: "Analytical",
                   lastContact: ("2026-10-14", "Agreed on the review format")),
        PersonNote(slug: "grace-hopper", name: "Grace Hopper", role: "Founder", company: "Compiler Co",
                   lastContact: ("2026-10-02", "Intro by mail")),
        PersonNote(slug: "alan-turing", name: "Alan Turing", role: "Research", company: "Bletchley Labs"),
    ]

    func today(now: Date) -> TodayFeed {
        let day = { (offset: Double) in AgentScanner.day(now.addingTimeInterval(offset * 86_400)) }
        return TodayFeed(
            now: [
                TodayItem(id: "t1", kind: .task, title: "Send the review notes to Ada", date: day(0), people: ["Ada Lovelace"]),
                TodayItem(id: "t2", kind: .task, title: "Draft the launch post", date: day(1)),
                TodayItem(id: "t3", kind: .task, title: "Book flights for the offsite"),
                TodayItem(id: "t4", kind: .task, title: "Clean up old branches"),
            ],
            followUps: [
                TodayItem(id: "f1", kind: .followUp, title: "Grace: contract draft", detail: "Waiting", date: day(-1), people: ["Grace Hopper"]),
                TodayItem(id: "f2", kind: .followUp, title: "Alan: benchmark numbers", detail: "Waiting", date: day(0), people: ["Alan Turing"]),
            ],
            confirmations: confirmations ? [
                TodayItem(id: "c1", kind: .confirm, title: "File the coffee receipt under travel?", detail: "Expenses · 2 items"),
                TodayItem(id: "c2", kind: .confirm, title: "Add the meetup to the calendar?", detail: "Mail from yesterday"),
            ] : [],
            brief: TodayBrief(title: "Morning brief", time: "07:30",
                              text: "Design review at 12:30: Ada wants the notes first. The launch post is due tomorrow."),
            counters: [TodayCounter(label: "Inbox", value: 3), TodayCounter(label: "Answers", value: 1)],
            emptyText: "All done."
        )
    }

    func people() -> [Person] { Self.people.map { Person(slug: $0.slug, name: $0.name) } }

    func prep(attendees: [String], now: Date) -> MeetingPrep {
        let matched = attendees.compactMap { name in Self.people.first { $0.name == name } }
        let unknown = attendees.filter { name in !Self.people.contains { $0.name == name } }
        var items: [MeetingPrep.Item] = []
        if matched.contains(where: { $0.slug == "ada-lovelace" }) {
            items.append(.init(source: .task, title: "Send the review notes to Ada", date: AgentScanner.day(now), person: "Ada"))
        }
        if matched.contains(where: { $0.slug == "grace-hopper" }) {
            items.append(.init(source: .waiting, title: "Grace: contract draft", date: AgentScanner.day(now), person: "Grace"))
        }
        return MeetingPrep(people: matched, unknown: unknown, items: items)
    }
}
