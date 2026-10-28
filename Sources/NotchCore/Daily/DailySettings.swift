import Foundation

/// The settings of the daily tools (weather, day progress, notes, health). Kept apart from
/// `SwitcherSettings`: the tools' switches stay there (`ToolFeature`), the details here.
public struct DailySettings: Codable, Equatable, Sendable {
    /// A city typed in Settings; nil asks the Mac where it is (approximate, once).
    public var place: GeoPlace?
    public var unit: TemperatureUnit
    /// Weather symbol and temperature beside the notch at rest.
    public var weatherInEar: Bool
    public var workDay: WorkDay
    /// The day's progress beside the notch at rest.
    public var progressInEar: Bool
    /// Folder for the notes; nil is `Application Support/<app>/notes`.
    public var notesFolder: String?
    /// Where sleep and recovery come from; nil until the user picks one.
    public var healthSource: HealthSource?
    /// The client id of the user's own WHOOP app (developer.whoop.com); the secret is in the Keychain.
    public var whoopClientID: String
    /// One line with last night's scores, once each morning.
    public var morningLine: Bool

    public init(place: GeoPlace? = nil, unit: TemperatureUnit = .celsius, weatherInEar: Bool = false, workDay: WorkDay = WorkDay(),
                progressInEar: Bool = false, notesFolder: String? = nil, healthSource: HealthSource? = nil,
                whoopClientID: String = "", morningLine: Bool = true) {
        self.place = place
        self.unit = unit
        self.weatherInEar = weatherInEar
        self.workDay = workDay
        self.progressInEar = progressInEar
        self.notesFolder = notesFolder
        self.healthSource = healthSource
        self.whoopClientID = whoopClientID
        self.morningLine = morningLine
    }

    /// Fahrenheit where the locale measures in it (US), Celsius elsewhere.
    public static func defaultUnit(for locale: Locale) -> TemperatureUnit {
        locale.measurementSystem == .us ? .fahrenheit : .celsius
    }

    // Tolerant decoding: a missing or unreadable key falls back to its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DailySettings()
        self.init(place: try? c.decodeIfPresent(GeoPlace.self, forKey: .place),
                  unit: (try? c.decodeIfPresent(TemperatureUnit.self, forKey: .unit)) ?? d.unit,
                  weatherInEar: (try? c.decodeIfPresent(Bool.self, forKey: .weatherInEar)) ?? d.weatherInEar,
                  workDay: (try? c.decodeIfPresent(WorkDay.self, forKey: .workDay)) ?? d.workDay,
                  progressInEar: (try? c.decodeIfPresent(Bool.self, forKey: .progressInEar)) ?? d.progressInEar,
                  notesFolder: try? c.decodeIfPresent(String.self, forKey: .notesFolder),
                  healthSource: try? c.decodeIfPresent(HealthSource.self, forKey: .healthSource),
                  whoopClientID: (try? c.decodeIfPresent(String.self, forKey: .whoopClientID)) ?? d.whoopClientID,
                  morningLine: (try? c.decodeIfPresent(Bool.self, forKey: .morningLine)) ?? d.morningLine)
    }
}
