import Foundation
import NotchCore

/// JSON for the daily tools' tests, which can't import Foundation themselves (see Package.swift).
public enum DailySettingsCodec {
    public static func decode(_ json: String) throws -> DailySettings {
        try JSONDecoder().decode(DailySettings.self, from: Data(json.utf8))
    }
}

extension Bytes {
    public static func string(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }
}

extension UTC {
    /// Gregorian calendar `hours` east of UTC (a user in Tokyo: 9).
    public static func calendar(hours: Int) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: hours * 3600)!
        return calendar
    }
}
