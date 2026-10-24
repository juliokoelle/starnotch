import Testing
import TestSupport
@testable import NotchCore

@Suite struct MeetingTests {
    @Test func findsLinksInEventFields() {
        let meet = MeetingLink.find(in: [nil, "Raum 2", "Join: https://meet.google.com/abc-defg-hij."])
        #expect(meet?.provider == .meet)
        #expect(meet?.url.absoluteString == "https://meet.google.com/abc-defg-hij")

        let zoom = MeetingLink.find(in: ["https://us02web.zoom.us/j/123456789?pwd=xyz"])
        #expect(zoom?.provider == .zoom)

        let teams = MeetingLink.find(in: [nil, nil, "<https://teams.microsoft.com/l/meetup-join/19%3ameeting_x/0?context=y>"])
        #expect(teams?.provider == .teams)
        #expect(teams?.url.absoluteString.hasSuffix(">") == false)
    }

    @Test func ignoresOtherLinksAndPrefersEarlierFields() {
        #expect(MeetingLink.find(in: ["https://zoom.us/pricing", "https://meet.google.com/"]) == nil)
        #expect(MeetingLink.find(in: ["no link here"]) == nil)
        let first = MeetingLink.find(in: ["https://zoom.us/j/1", "https://meet.google.com/aaa-bbbb-ccc"])
        #expect(first?.provider == .zoom)
    }

    @Test func countdownWording() {
        let now = UTC.date("2026-10-20 13:00")
        #expect(MeetingTime.countdown(start: UTC.date("2026-10-20 13:12"), end: UTC.date("2026-10-20 13:30"), now: now) == "in 12 min")
        #expect(MeetingTime.countdown(start: UTC.date("2026-10-20 14:05"), end: UTC.date("2026-10-20 15:00"), now: now) == "in 1 h 5 min")
        #expect(MeetingTime.countdown(start: UTC.date("2026-10-20 15:00"), end: UTC.date("2026-10-20 16:00"), now: now) == "in 2 h")
        #expect(MeetingTime.countdown(start: UTC.date("2026-10-20 12:50"), end: UTC.date("2026-10-20 13:20"), now: now) == "ends in 20 min")
        #expect(MeetingTime.countdown(start: now, end: UTC.date("2026-10-20 13:30"), now: now) == "ends in 30 min")
    }

    @Test func reminderWindow() {
        let now = UTC.date("2026-10-20 13:00")
        #expect(MeetingTime.isReminderDue(start: UTC.date("2026-10-20 13:05"), now: now))
        #expect(!MeetingTime.isReminderDue(start: UTC.date("2026-10-20 13:06"), now: now))
        #expect(!MeetingTime.isReminderDue(start: UTC.date("2026-10-20 12:59"), now: now))
    }

    @Test func eventKinds() {
        #expect(EventKind.classify(hasCallLink: true, otherAttendees: 0) == .call)
        #expect(EventKind.classify(hasCallLink: true, otherAttendees: 3) == .call)
        #expect(EventKind.classify(hasCallLink: false, otherAttendees: 2) == .meeting)
        // "Focus", "Writing": solo blocks.
        #expect(EventKind.classify(hasCallLink: false, otherAttendees: 0) == .focus)
        #expect(!EventKind.focus.takesAttention)
        #expect(EventKind.meeting.takesAttention)
        #expect(!EventKind.meeting.remindsAndJoins)
        #expect(EventKind.call.remindsAndJoins)
    }
}
