import Testing
import TestSupport
@testable import NotchCore

@Suite struct CaptureParserTests {
    // Wednesday, 21 October 2026, 10:00 UTC.
    let now = UTC.date("2026-10-21 10:00")
    let cal = UTC.calendar
    let people = [Person(slug: "ada-lovelace", name: "Ada Lovelace"), Person(slug: "grace", name: "Grace Hopper"),
                  Person(slug: "ada-x", name: "Ada Xu"), Person(slug: "alan-turing", name: "Alan Turing")]

    func due(_ text: String) -> String? {
        CaptureParser.parse(text, now: now, calendar: cal, people: people).dueField(calendar: cal)
    }

    @Test func relativeDays() {
        #expect(due("Angebot heute schicken") == "2026-10-21")
        #expect(due("morgen Grace anrufen") == "2026-10-22")
        #expect(due("übermorgen Garten gießen") == "2026-10-23")
        #expect(due("am Morgen joggen") == nil)
    }

    @Test func weekdays() {
        #expect(due("bis Freitag das Angebot") == "2026-10-23")
        #expect(due("am Montag Steuer") == "2026-10-26")
        #expect(due("Mittwoch Retro") == "2026-10-21")           // today is Wednesday
        #expect(due("nächsten Freitag Review") == "2026-10-30")
        #expect(due("nächste Woche Bank anrufen") == "2026-10-26")
    }

    @Test func datesAndTimes() {
        #expect(due("Abgabe 24.10.") == "2026-10-24")
        #expect(due("Abgabe 3.11.2026") == "2026-11-03")
        #expect(due("Geburtstag 2.1.") == "2027-01-02")          // past this year: next year
        #expect(due("morgen 16 Uhr Call") == "2026-10-22 16:00")
        #expect(due("Freitag 9:30 Arzt") == "2026-10-23 09:30")
        #expect(due("um 9 Standup") == "2026-10-22 09:00")       // 9 has passed today
        #expect(due("um 14 Uhr Mails") == "2026-10-21 14:00")
        #expect(due("Version 2.5 testen") == nil)
    }

    @Test func knownPeople() {
        let parse = CaptureParser.parse("Frage an Grace wegen Budget, Alan Turing in CC", now: now, calendar: cal, people: people)
        #expect(parse.people.map(\.slug) == ["grace", "alan-turing"])
        // "Ada" is ambiguous (two Adas): only the full name counts.
        #expect(CaptureParser.match(people: people, in: "Ada anrufen").isEmpty)
        #expect(CaptureParser.match(people: people, in: "Ada Lovelace anrufen").map(\.slug) == ["ada-lovelace"])
        #expect(CaptureParser.match(people: people, in: "Adam planen").isEmpty)
    }
}

@Suite struct CaptureParserEnglishTests {
    let now = UTC.date("2026-10-21 10:00")   // Wednesday

    func due(_ text: String) -> String? {
        CaptureParser.parse(text, now: now, calendar: UTC.calendar).dueField(calendar: UTC.calendar)
    }

    @Test func english() {
        #expect(due("send the offer by Friday") == "2026-10-23")
        #expect(due("call Grace tomorrow at 4pm") == "2026-10-22 16:00")
        #expect(due("next Monday dentist") == "2026-11-02")
        #expect(due("today 9:30 am standup") == "2026-10-21 09:30")
        #expect(due("day after tomorrow gym") == "2026-10-23")
        #expect(due("at 14 review") == "2026-10-21 14:00")
    }
}
