import Foundation

// Weather from Open-Meteo (open-meteo.com). Without a key the free API answers, which Open-Meteo
// allows for non-commercial use only; with a key (`[weather] api_key` in config.toml) the
// customer API does. The data is CC BY 4.0: the app credits it where the weather shows. The app
// asks for the forecast at most every 30 minutes and keeps the last answer on disk, so the card
// and the ear still show something offline.

public enum TemperatureUnit: String, Codable, CaseIterable, Sendable {
    case celsius, fahrenheit

    public var title: String { self == .celsius ? "°C" : "°F" }
}

/// A place to ask the weather for: a city typed in Settings, or where the Mac is.
public struct GeoPlace: Codable, Equatable, Hashable, Sendable {
    public var name: String
    /// Region or state ("Bavaria"), when the geocoder knows it.
    public var region: String?
    public var country: String?
    public var latitude: Double
    public var longitude: Double

    public init(name: String, region: String? = nil, country: String? = nil, latitude: Double, longitude: Double) {
        self.name = name
        self.region = region
        self.country = country
        self.latitude = latitude
        self.longitude = longitude
    }

    /// "Hamburg, Germany".
    public var label: String {
        [name, country].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ", ")
    }

    /// With the region, to tell places of the same name apart in a list ("Springfield, Illinois, United States").
    public var fullLabel: String {
        [name, region == name ? nil : region, country].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ", ")
    }
}

/// What the WMO weather code means, as a symbol and a word.
public enum WeatherCondition: String, Sendable {
    case clear, mostlyClear, partlyCloudy, overcast, fog, drizzle, freezingDrizzle, rain, heavyRain, freezingRain,
         snow, showers, snowShowers, thunderstorm

    public init(code: Int) {
        switch code {
        case 0: self = .clear
        case 1: self = .mostlyClear
        case 2: self = .partlyCloudy
        case 3: self = .overcast
        case 45, 48: self = .fog
        case 51, 53, 55: self = .drizzle
        case 56, 57: self = .freezingDrizzle
        case 61, 63: self = .rain
        case 65: self = .heavyRain
        case 66, 67: self = .freezingRain
        case 71, 73, 75, 77: self = .snow
        case 80, 81, 82: self = .showers
        case 85, 86: self = .snowShowers
        case 95, 96, 99: self = .thunderstorm
        default: self = .overcast
        }
    }

    public var title: String {
        switch self {
        case .clear: "Clear sky"
        case .mostlyClear: "Mostly clear"
        case .partlyCloudy: "Partly cloudy"
        case .overcast: "Overcast"
        case .fog: "Fog"
        case .drizzle: "Drizzle"
        case .freezingDrizzle: "Freezing drizzle"
        case .rain: "Rain"
        case .heavyRain: "Heavy rain"
        case .freezingRain: "Freezing rain"
        case .snow: "Snow"
        case .showers: "Showers"
        case .snowShowers: "Snow showers"
        case .thunderstorm: "Thunderstorm"
        }
    }

    /// An SF Symbol; sun or moon by the time of day.
    public func symbol(isDay: Bool) -> String {
        switch self {
        case .clear: isDay ? "sun.max.fill" : "moon.stars.fill"
        case .mostlyClear, .partlyCloudy: isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case .overcast: "cloud.fill"
        case .fog: "cloud.fog.fill"
        case .drizzle: "cloud.drizzle.fill"
        case .freezingDrizzle, .freezingRain: "cloud.sleet.fill"
        case .rain: "cloud.rain.fill"
        case .heavyRain: "cloud.heavyrain.fill"
        case .snow, .snowShowers: "cloud.snow.fill"
        case .showers: isDay ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill"
        case .thunderstorm: "cloud.bolt.rain.fill"
        }
    }
}

public struct WeatherHour: Codable, Equatable, Sendable {
    public var time: Date
    public var temperature: Double
    public var code: Int
    public var isDay: Bool
    /// Chance of rain or snow in percent.
    public var precipitation: Int?

    public init(time: Date, temperature: Double, code: Int, isDay: Bool, precipitation: Int? = nil) {
        self.time = time
        self.temperature = temperature
        self.code = code
        self.isDay = isDay
        self.precipitation = precipitation
    }

    public var condition: WeatherCondition { WeatherCondition(code: code) }
}

/// Now, today's high and low, and the hours ahead.
public struct WeatherReport: Codable, Equatable, Sendable {
    public var temperature: Double
    public var code: Int
    public var isDay: Bool
    public var high: Double
    public var low: Double
    public var hours: [WeatherHour]
    public var unit: TemperatureUnit
    /// When the forecast was fetched.
    public var fetched: Date
    /// Where it is for, as shown ("Hamburg").
    public var place: String?
    /// The coordinates asked for, and whether they were where the Mac is rather than a chosen
    /// city; nil in forecasts saved before they were kept.
    public var latitude: Double?
    public var longitude: Double?
    public var located: Bool?

    public init(temperature: Double, code: Int, isDay: Bool, high: Double, low: Double, hours: [WeatherHour],
                unit: TemperatureUnit, fetched: Date, place: String? = nil, latitude: Double? = nil, longitude: Double? = nil,
                located: Bool? = nil) {
        self.temperature = temperature
        self.code = code
        self.isDay = isDay
        self.high = high
        self.low = low
        self.hours = hours
        self.unit = unit
        self.fetched = fetched
        self.place = place
        self.latitude = latitude
        self.longitude = longitude
        self.located = located
    }

    public var condition: WeatherCondition { WeatherCondition(code: code) }
    public var symbol: String { condition.symbol(isDay: isDay) }

    /// Fetched within the last 30 minutes: no need to ask again.
    public static let refreshInterval: TimeInterval = 30 * 60
    /// Older than this, the forecast is no use any more and isn't shown.
    public static let maxAge: TimeInterval = 12 * 3600

    public func isFresh(at now: Date) -> Bool { now.timeIntervalSince(fetched) < Self.refreshInterval }
    public func isUsable(at now: Date) -> Bool { now.timeIntervalSince(fetched) < Self.maxAge }

    /// The hours from the current one on, at most `count`.
    public func upcoming(from now: Date, count: Int) -> [WeatherHour] {
        Array(hours.filter { $0.time.addingTimeInterval(3600) > now }.prefix(count))
    }

    /// "18°" (rounded, no unit: the unit is a setting).
    public static func degrees(_ value: Double) -> String {
        let rounded = Int(value.rounded())
        return "\(rounded == 0 ? 0 : rounded)°"
    }

    /// Whether this forecast is for the place set: the chosen city (nil asks where the Mac is).
    /// A forecast from before coordinates were kept passes only for where the Mac is.
    public func matches(_ place: GeoPlace?) -> Bool {
        guard let place else { return located != false }
        guard located != true, let latitude, let longitude else { return false }
        return abs(latitude - place.latitude) < 0.01 && abs(longitude - place.longitude) < 0.01
    }
}

public enum OpenMeteo {
    public enum Failure: Error { case unreadable }

    /// For the credit the licence asks for.
    public static let site = URL(string: "https://open-meteo.com")!
    public static let licence = URL(string: "https://creativecommons.org/licenses/by/4.0/")!

    /// The free API without a key (non-commercial use), the customer API with one.
    static func host(_ service: String, apiKey: String?) -> String {
        apiKey?.isEmpty == false ? "customer-\(service).open-meteo.com" : "\(service).open-meteo.com"
    }

    static func withKey(_ items: [URLQueryItem], _ apiKey: String?) -> [URLQueryItem] {
        guard let apiKey, !apiKey.isEmpty else { return items }
        return items + [URLQueryItem(name: "apikey", value: apiKey)]
    }

    /// Current conditions, the next two days by the hour, today's high and low, in the place's
    /// own time zone; times as Unix seconds.
    public static func forecastURL(latitude: Double, longitude: Double, unit: TemperatureUnit, apiKey: String? = nil) -> URL {
        var components = URLComponents(string: "https://\(host("api", apiKey: apiKey))/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.3f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.3f", longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "hourly", value: "temperature_2m,weather_code,precipitation_probability,is_day"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "2"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
        ] + (unit == .fahrenheit ? [URLQueryItem(name: "temperature_unit", value: "fahrenheit")] : [])
        components.queryItems = withKey(components.queryItems ?? [], apiKey)
        return components.url!
    }

    /// Places matching a typed name, in the interface language.
    public static func geocodingURL(name: String, language: String, apiKey: String? = nil) -> URL {
        var components = URLComponents(string: "https://\(host("geocoding-api", apiKey: apiKey))/v1/search")!
        components.queryItems = withKey([
            URLQueryItem(name: "name", value: name.trimmingCharacters(in: .whitespacesAndNewlines)),
            URLQueryItem(name: "count", value: "5"),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "format", value: "json"),
        ], apiKey)
        return components.url!
    }

    private struct Forecast: Decodable {
        struct Current: Decodable {
            var temperature_2m: Double
            var weather_code: Int
            var is_day: Int
        }
        struct Hourly: Decodable {
            var time: [Double]
            var temperature_2m: [Double?]
            var weather_code: [Int?]
            var precipitation_probability: [Int?]?
            var is_day: [Int?]?
        }
        struct Daily: Decodable {
            var temperature_2m_max: [Double?]
            var temperature_2m_min: [Double?]
        }
        var current: Current
        var hourly: Hourly
        var daily: Daily
    }

    /// `place` is what was asked for; `located` says it was where the Mac is.
    public static func parseForecast(_ data: Data, unit: TemperatureUnit, fetched: Date, place: GeoPlace? = nil,
                                     located: Bool = false) throws -> WeatherReport {
        guard let forecast = try? JSONDecoder().decode(Forecast.self, from: data) else { throw Failure.unreadable }
        let hourly = forecast.hourly
        var hours: [WeatherHour] = []
        for (index, time) in hourly.time.enumerated() {
            guard index < hourly.temperature_2m.count, let temperature = hourly.temperature_2m[index],
                  index < hourly.weather_code.count, let code = hourly.weather_code[index] else { continue }
            let isDay = hourly.is_day.flatMap { index < $0.count ? $0[index] : nil }.map { $0 == 1 } ?? true
            let rain = hourly.precipitation_probability.flatMap { index < $0.count ? $0[index] : nil }
            hours.append(WeatherHour(time: Date(timeIntervalSince1970: time), temperature: temperature, code: code,
                                     isDay: isDay, precipitation: rain))
        }
        let current = forecast.current
        // The first day is today where the place is; without it, the hours of the next day stand in.
        let high = forecast.daily.temperature_2m_max.first.flatMap { $0 } ?? hours.prefix(24).map(\.temperature).max() ?? current.temperature_2m
        let low = forecast.daily.temperature_2m_min.first.flatMap { $0 } ?? hours.prefix(24).map(\.temperature).min() ?? current.temperature_2m
        return WeatherReport(temperature: current.temperature_2m, code: current.weather_code, isDay: current.is_day == 1,
                             high: high, low: low, hours: hours, unit: unit, fetched: fetched, place: place?.name,
                             latitude: place?.latitude, longitude: place?.longitude, located: place == nil ? nil : located)
    }

    private struct Places: Decodable {
        struct Result: Decodable {
            var name: String
            var latitude: Double
            var longitude: Double
            var country: String?
            var admin1: String?
        }
        var results: [Result]?
    }

    public static func parsePlaces(_ data: Data) -> [GeoPlace] {
        guard let places = try? JSONDecoder().decode(Places.self, from: data) else { return [] }
        return (places.results ?? []).map {
            GeoPlace(name: $0.name, region: $0.admin1, country: $0.country, latitude: $0.latitude, longitude: $0.longitude)
        }
    }
}
