import Testing
import TestSupport
@testable import NotchCore

@Suite struct ReminderDraftTests {
    // Wednesday, 21 October 2026, 10:00 UTC.
    let now = UTC.date("2026-10-21 10:00")
    let cal = UTC.calendar

    func draft(_ text: String) -> ReminderDraft {
        var draft = ReminderDraft()
        draft.update(text: text, now: now, calendar: cal)
        return draft
    }

    @Test func readsTheDueDayAndTimeFromTheText() {
        let call = draft("Call Ada tomorrow 15:00")
        #expect(call.title == "Call Ada")
        let due = call.due(calendar: cal)
        #expect(due?.year == 2026 && due?.month == 10 && due?.day == 22 && due?.hour == 15 && due?.minute == 0)
        #expect(call.dayOffset(now: now, calendar: cal) == 1)
        let plain = draft("Buy oat milk")
        #expect(plain.title == "Buy oat milk" && plain.due(calendar: cal) == nil)
        // A due day without a time stays a day.
        let friday = draft("Steuer bis Freitag").due(calendar: cal)
        #expect(friday?.day == 23 && friday?.hour == nil)
        // Only date words: the text itself is the title.
        #expect(draft("today").title == "today")
        #expect(!draft("   ").canSave)
    }

    @Test func theChipCyclesAndTypingOnKeepsItsDay() {
        var draft = draft("Water the plants")
        draft.cycleDay(now: now, calendar: cal)
        #expect(draft.dayOffset(now: now, calendar: cal) == 0)
        draft.cycleDay(now: now, calendar: cal)
        #expect(draft.dayOffset(now: now, calendar: cal) == 1)
        draft.cycleDay(now: now, calendar: cal)
        #expect(UTC.string(draft.day) == "2026-10-26 00:00")      // next Monday
        // Typing on doesn't undo the picked day.
        draft.update(text: "Water the plants on the balcony", now: now, calendar: cal)
        #expect(UTC.string(draft.day) == "2026-10-26 00:00")
        draft.cycleDay(now: now, calendar: cal)
        #expect(draft.day == nil)
    }

    @Test func deletingTheDateWordsClearsTheirDate() {
        var draft = draft("Dentist tomorrow 9:30")
        #expect(draft.hour == 9 && draft.minute == 30)
        draft.update(text: "Dentist", now: now, calendar: cal)
        #expect(draft.day == nil && draft.hour == nil && draft.due(calendar: cal) == nil)
    }
}

@Suite struct EventDraftTests {
    let now = UTC.date("2026-10-21 10:10")   // Wednesday
    let cal = UTC.calendar

    @Test func startsAtTheNextHalfHourTodayAndAtNineOnAnotherDay() {
        #expect(UTC.string(EventDraft(day: now, now: now, calendar: cal).start) == "2026-10-21 10:30")
        let friday = UTC.date("2026-10-23 00:00")
        let later = EventDraft(day: friday, now: now, calendar: cal)
        #expect(UTC.string(later.start) == "2026-10-23 09:00" && later.minutes == 60)
        #expect(UTC.string(later.end) == "2026-10-23 10:00")
        // Late at night the next half hour would be tomorrow: the last one of today.
        let late = UTC.date("2026-10-21 23:40")
        #expect(UTC.string(EventDraft(day: late, now: late, calendar: cal).start) == "2026-10-21 23:30")
    }

    @Test func aTimeAloneStaysOnTheDayOnShow() {
        var draft = EventDraft(day: UTC.date("2026-10-23 00:00"), now: now, calendar: cal)
        draft.update(text: "Lunch with Ada 13:00", now: now, calendar: cal)
        #expect(UTC.string(draft.start) == "2026-10-23 13:00")
        #expect(draft.title == "Lunch with Ada")
        // A named day moves it.
        draft.update(text: "Lunch with Ada tomorrow 13:00", now: now, calendar: cal)
        #expect(UTC.string(draft.start) == "2026-10-22 13:00")
    }

    @Test func readsALength() {
        var draft = EventDraft(day: now, now: now, calendar: cal)
        draft.update(text: "Review 14:00 30 min", now: now, calendar: cal)
        #expect(draft.minutes == 30 && draft.title == "Review")
        draft.update(text: "Workshop 9:00 1,5 Std", now: now, calendar: cal)
        #expect(draft.minutes == 90 && draft.title == "Workshop")
        draft.update(text: "Deep work 2h", now: now, calendar: cal)
        #expect(draft.minutes == 120 && draft.title == "Deep work")
        #expect(EventDraft.length(in: "Call at 9am") == nil)
        #expect(EventDraft.length(in: "Sprint 900 min") == nil)
    }

    @Test func theChipsChangeItAndTypingOnKeepsThat() {
        var draft = EventDraft(day: now, now: now, calendar: cal)
        draft.update(text: "Standup 9:00", now: now, calendar: cal)
        draft.shift(minutes: 15, calendar: cal)
        draft.shift(days: 1, calendar: cal)
        draft.nextLength()
        #expect(UTC.string(draft.start) == "2026-10-22 09:15" && draft.minutes == 90)
        // The same time in the text doesn't count again while the title grows.
        draft.update(text: "Standup 9:00 with the team", now: now, calendar: cal)
        #expect(UTC.string(draft.start) == "2026-10-22 09:15")
        // The time chip doesn't leave the day; the length chip goes round.
        var edge = EventDraft(day: UTC.date("2026-10-23 00:00"), now: now, calendar: cal)
        edge.update(text: "Late 23:50", now: now, calendar: cal)
        edge.shift(minutes: 15, calendar: cal)
        #expect(UTC.string(edge.start) == "2026-10-23 23:50")
        edge.update(text: "Late 23:50 2h", now: now, calendar: cal)
        edge.nextLength()
        #expect(edge.minutes == 15)
    }
}

@Suite struct CaptureParseImpliedDayTests {
    @Test func aTimeAloneSaysItsDayIsImplied() {
        let now = UTC.date("2026-10-21 10:00")
        #expect(CaptureParser.parse("um 14 Uhr Mails", now: now, calendar: UTC.calendar).dayIsImplied)
        #expect(!CaptureParser.parse("morgen 16 Uhr Call", now: now, calendar: UTC.calendar).dayIsImplied)
        #expect(!CaptureParser.parse("bis Freitag", now: now, calendar: UTC.calendar).dayIsImplied)
    }
}
