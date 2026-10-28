import Foundation

/// When a plan window runs out at the current pace: from the samples of the used percentage,
/// the rate over the last stretch, projected to 100 %.
public enum PaceForecast {
    public enum Outcome: Equatable, Sendable {
        /// Hits the limit before the reset, at this time.
        case hitsLimit(at: Date)
        /// Lasts until the reset.
        case lasts(until: Date?)
        /// Not enough samples or no change.
        case unknown
    }

    /// `samples`: (time, used %) in any order. Uses the last `window` seconds of samples.
    public static func forecast(samples: [(at: Date, used: Double)], resetsAt: Date?, now: Date,
                                window: TimeInterval = 45 * 60) -> Outcome {
        let recent = samples.filter { now.timeIntervalSince($0.at) <= window && $0.at <= now }.sorted { $0.at < $1.at }
        guard let first = recent.first, let last = recent.last, last.at.timeIntervalSince(first.at) >= 5 * 60 else { return .unknown }
        let rate = (last.used - first.used) / last.at.timeIntervalSince(first.at)  // % per second
        guard rate > 0 else { return resetsAt.map { .lasts(until: $0) } ?? .unknown }
        let hit = last.at.addingTimeInterval((100 - last.used) / rate)
        if let resetsAt, hit >= resetsAt { return .lasts(until: resetsAt) }
        return .hitsLimit(at: hit)
    }

    /// The forecast without waiting for samples: the recent rate once the samples span five
    /// minutes (`forecast`), before that the window's average rate since it opened (`minutes`
    /// before its reset). Too early to say (under a tenth of the window gone, under 2 % used): unknown.
    public static func projection(usedPercent: Double, minutes: Int?, resetsAt: Date?,
                                  samples: [(at: Date, used: Double)] = [], now: Date) -> Outcome {
        let recent = forecast(samples: samples, resetsAt: resetsAt, now: now)
        guard recent == .unknown else { return recent }
        guard let minutes, minutes > 0, let resetsAt, resetsAt > now else { return .unknown }
        if usedPercent >= 100 { return .hitsLimit(at: now) }
        let length = Double(minutes) * 60
        let elapsed = now.timeIntervalSince(resetsAt.addingTimeInterval(-length))
        guard elapsed >= length * 0.1, elapsed <= length, usedPercent >= 2 else { return .unknown }
        let rate = usedPercent / elapsed  // % per second
        let hit = now.addingTimeInterval((100 - usedPercent) / rate)
        return hit >= resetsAt ? .lasts(until: resetsAt) : .hitsLimit(at: hit)
    }

    /// "At this pace you hit the 5 h limit at 14:20", "Lasts until the reset at 16:00".
    public static func sentence(_ outcome: Outcome, window: String, clock: (Date) -> String) -> String? {
        switch outcome {
        case .hitsLimit(let at): "At this pace you hit the \(window) limit at \(clock(at))"
        case .lasts(let until): until.map { "Lasts until the reset at \(clock($0))" } ?? "Lasts until the reset"
        case .unknown: nil
        }
    }

    /// The alert thresholds: one sneak when crossing 80 % and one at 90 %.
    public static func crossed(previous: Double?, current: Double) -> Int? {
        for threshold in [90, 80] where current >= Double(threshold) && (previous ?? 0) < Double(threshold) { return threshold }
        return nil
    }
}

/// The battery as IOKit's power sources describe it.
public struct BatteryState: Equatable, Sendable {
    public var percent: Int
    public var charging: Bool
    public var pluggedIn: Bool
    /// Minutes to empty (on battery) or to full (charging); nil while macOS estimates.
    public var minutesLeft: Int?

    public init(percent: Int, charging: Bool, pluggedIn: Bool, minutesLeft: Int?) {
        self.percent = percent
        self.charging = charging
        self.pluggedIn = pluggedIn
        self.minutesLeft = minutesLeft
    }

    /// From one power source description (`IOPSGetPowerSourceDescription`); nil for non-batteries.
    public static func parse(_ description: [String: Any]) -> BatteryState? {
        guard (description["Type"] as? String) == "InternalBattery",
              let current = description["Current Capacity"] as? Int, let max = description["Max Capacity"] as? Int, max > 0 else { return nil }
        let charging = description["Is Charging"] as? Bool ?? false
        let plugged = (description["Power Source State"] as? String) == "AC Power"
        let key = charging ? "Time to Full Charge" : "Time to Empty"
        let minutes = (description[key] as? Int).flatMap { $0 > 0 ? $0 : nil }
        return BatteryState(percent: Int((Double(current) / Double(max) * 100).rounded()), charging: charging,
                            pluggedIn: plugged, minutesLeft: minutes)
    }

    /// "64 % · charging, full in 1 h 10", "18 % · 1 h 05 left", "100 % · on power".
    public var line: String {
        func duration(_ minutes: Int) -> String { minutes >= 60 ? String(format: "%d h %02d", minutes / 60, minutes % 60) : "\(minutes) min" }
        if charging { return "\(percent) % · charging" + (minutesLeft.map { ", full in \(duration($0))" } ?? "") }
        if pluggedIn { return "\(percent) % · on power" }
        return "\(percent) %" + (minutesLeft.map { " · \(duration($0)) left" } ?? "")
    }

    /// Low enough to say so: 10 % or less on battery.
    public var isLow: Bool { !pluggedIn && percent <= 10 }
}

extension CaptureParse {
    /// Start of an event when the text names a day and a time.
    public func eventStart(calendar: Calendar) -> Date? {
        guard let day, let hour else { return nil }
        return calendar.date(bySettingHour: hour, minute: minute ?? 0, second: 0, of: day)
    }
}

extension CaptureParser {
    /// The text without its date and time words, for an event title ("Call Ada tomorrow at 15:00"
    /// → "Call Ada").
    public static func title(removingDatesFrom text: String) -> String {
        var result = text
        let patterns = [#"\b(um|at)\s+([01]?\d|2[0-3])\b(?![.:]\d)"#, #"\b(am|um|at|on|bis|by)\s+(?=\d|montag|dienstag|mittwoch|donnerstag|freitag|samstag|sonntag|monday|tuesday|wednesday|thursday|friday|saturday|sunday)"#,
                        #"\b(nächsten|nächste|kommenden|next)\s+(?=montag|dienstag|mittwoch|donnerstag|freitag|samstag|sonntag|monday|tuesday|wednesday|thursday|friday|saturday|sunday|woche|week)"#,
                        #"\b(übermorgen|day after tomorrow|morgen|tomorrow|heute|today|tonight|nächste woche|next week)\b"#,
                        #"\b(montag|dienstag|mittwoch|donnerstag|freitag|samstag|sonntag|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"#,
                        #"\b\d{1,2}\.\d{1,2}\.(\d{4})?"#,
                        #"\b([01]?\d|2[0-3])[:.][0-5]\d\s*(uhr)?\b"#, #"\b([01]?\d|2[0-3])\s*uhr\b"#,
                        #"\b(1[0-2]|0?[1-9])(:[0-5]\d)?\s*(am|pm)\b"#]
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        return result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,.-–:"))
    }
}
