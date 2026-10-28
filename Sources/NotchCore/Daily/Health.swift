import CryptoKit
import Foundation

// Sleep and recovery from a wearable: Oura (personal access token) or WHOOP (OAuth 2). The
// tokens live in the Keychain; this file only builds requests and reads answers.

public enum HealthSource: String, Codable, CaseIterable, Sendable {
    case oura, whoop

    public var title: String { self == .oura ? "Oura" : "WHOOP" }
}

/// Last night, as the wearable scored it.
public struct HealthDay: Codable, Equatable, Sendable {
    public var source: HealthSource
    /// The day the scores belong to, `yyyy-MM-dd`.
    public var day: String
    /// Oura sleep score, or WHOOP sleep performance in percent.
    public var sleep: Int?
    /// Oura readiness score.
    public var readiness: Int?
    /// WHOOP recovery in percent.
    public var recovery: Int?
    public var restingHeartRate: Int?
    public var hrv: Double?
    public var fetched: Date

    public init(source: HealthSource, day: String, sleep: Int? = nil, readiness: Int? = nil, recovery: Int? = nil,
                restingHeartRate: Int? = nil, hrv: Double? = nil, fetched: Date) {
        self.source = source
        self.day = day
        self.sleep = sleep
        self.readiness = readiness
        self.recovery = recovery
        self.restingHeartRate = restingHeartRate
        self.hrv = hrv
        self.fetched = fetched
    }

    /// The number that says how ready the body is: readiness (Oura) or recovery (WHOOP), 0 to 100.
    public var headline: Int? { readiness ?? recovery }
    public var headlineTitle: String { recovery != nil && readiness == nil ? "Recovery" : "Readiness" }

    /// Good, okay or low, by the wearables' own bands (WHOOP: green from 67, red below 34;
    /// Oura: optimal from 85, pay attention below 70).
    public enum Level: Sendable { case good, fair, low }

    public static func level(_ score: Int, source: HealthSource) -> Level {
        switch source {
        case .whoop: score >= 67 ? .good : score >= 34 ? .fair : .low
        case .oura: score >= 85 ? .good : score >= 70 ? .fair : .low
        }
    }

    /// "Readiness 80 · Sleep 84", "Recovery 72 % · Sleep 91 %".
    public var line: String {
        var parts: [String] = []
        if let readiness { parts.append("Readiness \(readiness)") }
        if let recovery { parts.append("Recovery \(recovery) %") }
        if let sleep { parts.append(source == .whoop ? "Sleep \(sleep) %" : "Sleep \(sleep)") }
        return parts.joined(separator: " · ")
    }

    public var isEmpty: Bool { sleep == nil && readiness == nil && recovery == nil }
}

/// The morning line: once a day, the first time the Mac is in use from 5 in the morning on.
public enum MorningLine {
    public static let earliestHour = 5

    public static func isDue(lastShown: String?, now: Date, calendar: Calendar = .current) -> Bool {
        calendar.component(.hour, from: now) >= earliestHour && lastShown != day(now, calendar: calendar)
    }

    /// `yyyy-MM-dd` in the user's time zone.
    public static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

// MARK: Oura

/// Oura API v2 with a personal access token (cloud.ouraring.com/personal-access-tokens).
public enum OuraAPI {
    public static let tokenPage = URL(string: "https://cloud.ouraring.com/personal-access-tokens")!

    /// `daily_sleep` or `daily_readiness` from one day to another (both inclusive, `yyyy-MM-dd`).
    public static func url(_ collection: String, from start: String, to end: String) -> URL {
        var components = URLComponents(string: "https://api.ouraring.com/v2/usercollection/\(collection)")!
        components.queryItems = [URLQueryItem(name: "start_date", value: start), URLQueryItem(name: "end_date", value: end)]
        return components.url!
    }

    private struct Collection: Decodable {
        struct Entry: Decodable {
            var day: String
            var score: Int?
        }
        var data: [Entry]
    }

    /// The latest day with a score.
    public static func latestScore(_ data: Data) -> (day: String, score: Int)? {
        guard let collection = try? JSONDecoder().decode(Collection.self, from: data) else { return nil }
        return collection.data.filter { $0.score != nil }.max { $0.day < $1.day }.map { ($0.day, $0.score!) }
    }
}

// MARK: WHOOP

/// WHOOP API v2. The user registers an app at developer.whoop.com with the redirect URL
/// `<scheme>://oauth/whoop` and enters its client id and secret in Settings.
public enum WhoopAPI {
    public static let authorizeURL = URL(string: "https://api.prod.whoop.com/oauth/oauth2/auth")!
    public static let tokenURL = URL(string: "https://api.prod.whoop.com/oauth/oauth2/token")!
    public static let recoveryURL = URL(string: "https://api.prod.whoop.com/developer/v2/recovery?limit=1")!
    public static let sleepURL = URL(string: "https://api.prod.whoop.com/developer/v2/activity/sleep?limit=5")!
    public static let dashboard = URL(string: "https://developer.whoop.com")!
    /// `offline` brings a refresh token, so the user signs in once.
    public static let scopes = "read:recovery read:sleep read:cycles offline"

    public static func redirectURI(scheme: String) -> String { "\(scheme)://oauth/whoop" }

    public static func authorize(clientID: String, redirect: String, state: String, challenge: String) -> URL {
        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return components.url!
    }

    /// The form body that trades the code for tokens.
    public static func tokenBody(code: String, verifier: String, clientID: String, secret: String?, redirect: String) -> Data {
        form([("grant_type", "authorization_code"), ("code", code), ("code_verifier", verifier), ("client_id", clientID),
              ("client_secret", secret), ("redirect_uri", redirect)])
    }

    public static func refreshBody(refreshToken: String, clientID: String, secret: String?) -> Data {
        form([("grant_type", "refresh_token"), ("refresh_token", refreshToken), ("client_id", clientID),
              ("client_secret", secret), ("scope", "offline")])
    }

    /// `application/x-www-form-urlencoded`, empty values left out.
    static func form(_ fields: [(String, String?)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let pairs = fields.compactMap { key, value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }

    public struct Token: Codable, Equatable, Sendable {
        public var access: String
        public var refresh: String?
        public var expires: Date

        public init(access: String, refresh: String?, expires: Date) {
            self.access = access
            self.refresh = refresh
            self.expires = expires
        }

        /// A minute of slack, so a request never goes out with a token about to lapse.
        public func isValid(at now: Date) -> Bool { expires.timeIntervalSince(now) > 60 }
    }

    private struct TokenAnswer: Decodable {
        var access_token: String
        var refresh_token: String?
        var expires_in: Double?
    }

    public static func parseToken(_ data: Data, now: Date) -> Token? {
        guard let answer = try? JSONDecoder().decode(TokenAnswer.self, from: data) else { return nil }
        return Token(access: answer.access_token, refresh: answer.refresh_token, expires: now.addingTimeInterval(answer.expires_in ?? 3600))
    }

    private struct Records<Score: Decodable>: Decodable {
        struct Record: Decodable {
            var score_state: String?
            var nap: Bool?
            var created_at: String?
            var start: String?
            var score: Score?
        }
        var records: [Record]
    }

    private struct RecoveryScore: Decodable {
        var recovery_score: Double?
        var resting_heart_rate: Double?
        var hrv_rmssd_milli: Double?
    }

    private struct SleepScore: Decodable {
        var sleep_performance_percentage: Double?
    }

    /// The latest scored recovery: percent, resting heart rate, HRV (ms), and its day (`yyyy-MM-dd` of `created_at`).
    public static func parseRecovery(_ data: Data) -> (recovery: Int, restingHeartRate: Int?, hrv: Double?, day: String?)? {
        guard let page = try? JSONDecoder().decode(Records<RecoveryScore>.self, from: data),
              let record = page.records.first(where: { $0.score_state == "SCORED" && $0.score?.recovery_score != nil }),
              let score = record.score, let recovery = score.recovery_score else { return nil }
        return (Int(recovery.rounded()), score.resting_heart_rate.map { Int($0.rounded()) }, score.hrv_rmssd_milli,
                record.created_at.map { String($0.prefix(10)) })
    }

    /// Sleep performance of the latest scored night's sleep (naps left out).
    public static func parseSleep(_ data: Data) -> Int? {
        guard let page = try? JSONDecoder().decode(Records<SleepScore>.self, from: data) else { return nil }
        return page.records.first { $0.score_state == "SCORED" && $0.nap != true && $0.score?.sleep_performance_percentage != nil }?
            .score?.sleep_performance_percentage.map { Int($0.rounded()) }
    }
}

/// Proof Key for Code Exchange (RFC 7636), S256.
public enum PKCE {
    /// 32 random bytes as base64url: 43 characters.
    public static func verifier() -> String {
        var generator = SystemRandomNumberGenerator()
        return base64url(Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    public static func challenge(for verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// A random `state` (WHOOP wants at least eight characters).
    public static func state() -> String { String(verifier().prefix(16)) }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
