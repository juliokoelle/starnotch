import Foundation

/// How Apple Maps works out the way to an event (Settings › Tools › Time to leave).
public enum TravelMode: String, Codable, CaseIterable, Sendable {
    case driving, transit, walking

    public var title: String {
        switch self {
        case .driving: "Car"
        case .transit: "Transit"
        case .walking: "Walk"
        }
    }

    public var symbol: String {
        switch self {
        case .driving: "car.fill"
        case .transit: "tram.fill"
        case .walking: "figure.walk"
        }
    }
}

/// Time to leave for today's events with a place: when the way there takes `travel`, the line
/// shows from a minute before the moment to go until the event starts, once per event.
public enum TimeToLeave {
    /// A route shorter than this: already there. Longer: not a way across town (or the search
    /// found the wrong place).
    public static let shortest: TimeInterval = 2 * 60
    public static let longest: TimeInterval = 3 * 3600
    /// Events starting within this are looked up; again when the answer is older than `refresh`.
    public static let horizon: TimeInterval = 4 * 3600
    public static let refresh: TimeInterval = 15 * 60
    /// A lookup that found no place or no route is tried again after this long.
    public static let retry: TimeInterval = 30 * 60
    /// The line comes this long before the moment to go.
    public static let lead: TimeInterval = 60

    /// An answer from Apple Maps worth showing.
    public static func usable(_ travel: TimeInterval) -> Bool { travel >= shortest && travel <= longest }

    public static func leaveAt(start: Date, travel: TimeInterval) -> Date { start.addingTimeInterval(-travel) }

    /// Time to go: from `lead` before the moment until the event starts (late is still worth saying).
    public static func isDue(start: Date, travel: TimeInterval, now: Date) -> Bool {
        now < start && now >= start.addingTimeInterval(-travel - lead)
    }

    /// Whether an event has somewhere to go. A call's location ("Microsoft Teams Meeting") and a
    /// meeting room aren't places; coordinates Calendar knows always are.
    public static func hasPlace(location: String?, hasCoordinate: Bool, hasCallLink: Bool, isRoom: Bool) -> Bool {
        if isRoom { return false }
        if hasCoordinate { return true }
        let text = location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !text.isEmpty && !text.contains("://") && !hasCallLink
    }

    /// Whether to ask Apple Maps (again): the event starts within the horizon, nothing failed
    /// lately, and the last answer is old. Once the moment to go has come the answer stays.
    public static func needsLookup(start: Date, now: Date, found: Date?, travel: TimeInterval?, failed: Date?) -> Bool {
        guard start > now, start.timeIntervalSince(now) <= horizon else { return false }
        if let failed, now.timeIntervalSince(failed) < retry { return false }
        guard let found, let travel else { return true }
        return now.timeIntervalSince(found) >= refresh && now < start.addingTimeInterval(-travel - lead)
    }

    /// "18 min", "1 h", "1 h 5 min".
    public static func duration(_ travel: TimeInterval) -> String {
        let minutes = max(1, Int((travel / 60).rounded(.up)))
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }
}

/// The events whose line was shown today, kept across a restart: never two lines for one event.
public struct LeaveAlerts: Codable, Equatable, Sendable {
    public private(set) var day: String
    public private(set) var ids: [String]

    public init(day: String = "", ids: [String] = []) {
        self.day = day
        self.ids = ids
    }

    public func contains(_ id: String, day: String) -> Bool { self.day == day && ids.contains(id) }

    /// A new day starts empty.
    public mutating func insert(_ id: String, day: String) {
        if self.day != day { self = LeaveAlerts(day: day) }
        if !ids.contains(id) { ids.append(id) }
    }
}
