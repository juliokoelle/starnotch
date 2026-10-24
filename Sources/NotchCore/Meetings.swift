import Foundation

/// A video call link found in a calendar event.
public struct MeetingLink: Equatable, Sendable {
    public enum Provider: String, Sendable {
        case meet = "Meet", zoom = "Zoom", teams = "Teams"
    }

    public var provider: Provider
    public var url: URL

    public init(provider: Provider, url: URL) {
        self.provider = provider
        self.url = url
    }

    /// The first Meet, Zoom or Teams link in the event's URL, location or notes (in that order).
    public static func find(in texts: [String?]) -> MeetingLink? {
        for text in texts.compactMap({ $0 }) {
            for match in text.matches(of: #/https?:\/\/[^\s<>"')\]]+/#) {
                var raw = String(match.output)
                while let last = raw.last, ".,;:!?".contains(last) { raw.removeLast() }
                guard let url = URL(string: raw), let host = url.host?.lowercased() else { continue }
                if host == "meet.google.com", url.path.count > 1 { return MeetingLink(provider: .meet, url: url) }
                if host == "zoom.us" || host.hasSuffix(".zoom.us"), url.path.hasPrefix("/j/") || url.path.hasPrefix("/my/") {
                    return MeetingLink(provider: .zoom, url: url)
                }
                if host == "teams.microsoft.com" || host == "teams.live.com", url.path.contains("meet") {
                    return MeetingLink(provider: .teams, url: url)
                }
            }
        }
        return nil
    }
}

public enum MeetingTime {
    /// "in 12 min", "in 1 h 5 min", "now", "ends in 20 min" (running).
    public static func countdown(start: Date, end: Date, now: Date) -> String {
        if now >= start {
            let left = Int((end.timeIntervalSince(now) / 60).rounded(.up))
            return left > 0 ? "ends in \(left) min" : "ended"
        }
        let minutes = Int((start.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 0 { return "now" }
        if minutes < 60 { return "in \(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "in \(hours) h" : "in \(hours) h \(rest) min"
    }

    /// The moment to remind: within `lead` before the start, but not after it started.
    public static func isReminderDue(start: Date, now: Date, lead: TimeInterval = 5 * 60) -> Bool {
        let until = start.timeIntervalSince(now)
        return until > 0 && until <= lead
    }
}

/// What a calendar event is, for the notch: only calls get the camera, Join and the reminder.
public enum EventKind: Equatable, Sendable {
    /// Has a Meet, Zoom or Teams link.
    case call
    /// Other people are invited, no call link (in person, phone).
    case meeting
    /// A block in the user's own calendar: no other attendees, no link ("Focus", "Writing").
    case focus

    /// - Parameter otherAttendees: invited people other than the user.
    public static func classify(hasCallLink: Bool, otherAttendees: Int) -> EventKind {
        if hasCallLink { return .call }
        return otherAttendees > 0 ? .meeting : .focus
    }

    /// Focus blocks never take the notch's ears.
    public var takesAttention: Bool { self != .focus }
    /// The five-minute reminder and Join only make sense with a link.
    public var remindsAndJoins: Bool { self == .call }
}
