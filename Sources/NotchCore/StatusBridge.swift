import Foundation

/// What Claude Code hands its status line on stdin (written per session by
/// `scripts/statusline-bridge.sh`): context window and, for Pro/Max plans, the official
/// 5-hour and weekly limits.
public struct StatusSnapshot: Equatable, Sendable {
    public struct Limit: Equatable, Sendable {
        /// 0...100
        public var usedPercentage: Double
        public var resetsAt: Date?

        public init(usedPercentage: Double, resetsAt: Date?) {
            self.usedPercentage = usedPercentage
            self.resetsAt = resetsAt
        }
    }

    public var sessionID: String
    public var contextUsedPercentage: Double?
    public var contextWindowSize: Int?
    public var fiveHour: Limit?
    public var sevenDay: Limit?
    public var model: String?
    /// When the bridge wrote it (file modification time).
    public var capturedAt: Date

    public init(sessionID: String, contextUsedPercentage: Double? = nil, contextWindowSize: Int? = nil,
                fiveHour: Limit? = nil, sevenDay: Limit? = nil, model: String? = nil, capturedAt: Date) {
        self.sessionID = sessionID
        self.contextUsedPercentage = contextUsedPercentage
        self.contextWindowSize = contextWindowSize
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.model = model
        self.capturedAt = capturedAt
    }

    public static func parse(_ data: Data, capturedAt: Date) -> StatusSnapshot? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["session_id"] as? String, !id.isEmpty else { return nil }
        func number(_ value: Any?) -> Double? {
            if let n = value as? NSNumber { return n.doubleValue }
            if let s = value as? String { return Double(s) }
            return nil
        }
        func date(_ value: Any?) -> Date? {
            if let seconds = number(value) {
                // Epoch seconds; milliseconds if it's clearly too large.
                return Date(timeIntervalSince1970: seconds > 1e11 ? seconds / 1000 : seconds)
            }
            if let string = value as? String { return SessionLog.parseDate(string) }
            return nil
        }
        func limit(_ value: Any?) -> Limit? {
            guard let dict = value as? [String: Any], let used = number(dict["used_percentage"]) else { return nil }
            return Limit(usedPercentage: used, resetsAt: date(dict["resets_at"]))
        }
        let context = object["context_window"] as? [String: Any]
        let limits = object["rate_limits"] as? [String: Any]
        let model = (object["model"] as? [String: Any])?["id"] as? String
        return StatusSnapshot(
            sessionID: id,
            contextUsedPercentage: number(context?["used_percentage"]),
            contextWindowSize: number(context?["context_window_size"]).map { Int($0) },
            fiveHour: limit(limits?["five_hour"]),
            sevenDay: limit(limits?["seven_day"]),
            model: model,
            capturedAt: capturedAt
        )
    }
}

public enum UsageText {
    /// "53 m left" → "53 m", "2 h 14 m left" → "2 h 14 m".
    public static func short(_ left: String) -> String {
        left.hasSuffix(" left") ? String(left.dropLast(5)) : left
    }

    /// "2 h 14 m left", "38 m left", "resetting".
    public static func left(until date: Date, now: Date) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds > 0 else { return "resetting" }
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours) h \(minutes) m left" : "\(max(1, minutes)) m left"
    }

    /// "resets Tue" (English weekday), or "resets today 18:00".
    public static func resetDay(_ date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            return String(format: "resets today %02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        }
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return "resets \(names[calendar.component(.weekday, from: date) - 1])"
    }

    /// Context fullness: amber from 70 %, red from 90 %.
    public static func contextLevel(_ percentage: Double) -> QuotaEstimator.Level {
        percentage >= 90 ? .critical : percentage >= 70 ? .warn : .calm
    }
}
