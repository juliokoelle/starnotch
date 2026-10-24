import Foundation

/// Date helpers for tests, which can't import Foundation themselves (see Package.swift).
public enum UTC {
    /// `"2026-10-20 04:31"` in UTC.
    public static func date(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: string)!
    }

    /// Formats like `date(_:)`, or `"nil"`.
    public static func string(_ date: Date?) -> String {
        guard let date else { return "nil" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    public static func seconds(_ date: Date?) -> Double? { date?.timeIntervalSince1970 }

    /// Tokens per hour for quota tests, keyed by "yyyy-MM-dd HH:mm".
    public static func hourly(_ entries: [(String, Int)]) -> [Date: Int] {
        Dictionary(uniqueKeysWithValues: entries.map { (date($0.0), $0.1) })
    }

    /// Gregorian calendar in UTC.
    public static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
}

public enum Bytes {
    public static func data(_ string: String) -> Data { Data(string.utf8) }
    public static func url(_ string: String) -> URL { URL(string: string)! }
}

extension Bytes {
    public static func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }
}
