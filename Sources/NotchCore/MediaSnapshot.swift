import Foundation

/// What plays system-wide, as the MediaRemote helper reports it (one JSON object per line, see
/// helpers/mediaremote). Any app that shows in Control Center's Now Playing shows here: Spotify,
/// Music, Podcasts, VLC, IINA, and the browsers (YouTube, SoundCloud, Spotify on the web).
public struct MediaSnapshot: Equatable, Sendable {
    /// The app that plays: for a web page the browser, not its helper process.
    public var appID: String
    public var title: String
    public var artist: String
    public var album: String
    /// Seconds; 0 when the player doesn't say (live streams).
    public var duration: Double
    /// The position at `timestamp`.
    public var elapsed: Double
    public var timestamp: Date?
    public var rate: Double
    public var isPlaying: Bool
    /// The cover, only in the lines where it changed.
    public var artwork: Data?

    public init(appID: String, title: String, artist: String = "", album: String = "", duration: Double = 0,
                elapsed: Double = 0, timestamp: Date? = nil, rate: Double = 1, isPlaying: Bool = true, artwork: Data? = nil) {
        self.appID = appID
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.elapsed = elapsed
        self.timestamp = timestamp
        self.rate = rate
        self.isPlaying = isPlaying
        self.artwork = artwork
    }

    /// One track: players hand out a new identifier with every update, so title, artist and album
    /// say which track it is.
    public var trackKey: String { "\(appID)|\(title)|\(artist)|\(album)" }

    /// Where playback is now: the reported position plus the time since, while it plays.
    public func position(at now: Date) -> Double {
        guard isPlaying, let timestamp else { return clamp(elapsed) }
        return clamp(elapsed + max(0, now.timeIntervalSince(timestamp)) * (rate > 0 ? rate : 1))
    }

    private func clamp(_ value: Double) -> Double { duration > 0 ? min(max(0, value), duration) : max(0, value) }

    public enum Line: Equatable, Sendable {
        /// Nothing plays (or the player went away).
        case nothing
        case playing(MediaSnapshot)
    }

    /// One line of the helper's output; nil when it isn't one (a broken line, a log message).
    public static func parse(_ line: Data) -> Line? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        let title = (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { return .nothing }
        func text(_ key: String) -> String { (object[key] as? String)?.trimmingCharacters(in: .whitespaces) ?? "" }
        func number(_ key: String) -> Double? { (object[key] as? NSNumber)?.doubleValue }
        let app = MediaApps.owner(bundleID: object["bundleID"] as? String, clientID: object["clientID"] as? String,
                                  parentID: object["parentID"] as? String)
        return .playing(MediaSnapshot(
            appID: app ?? "",
            title: title,
            artist: text("artist"),
            album: text("album"),
            duration: max(0, number("duration") ?? 0),
            elapsed: max(0, number("elapsed") ?? 0),
            timestamp: number("timestamp").map { Date(timeIntervalSince1970: $0) },
            rate: number("rate") ?? 1,
            isPlaying: (object["playing"] as? Bool) ?? ((number("rate") ?? 0) > 0),
            artwork: (object["artwork"] as? String).flatMap { Data(base64Encoded: $0) }
        ))
    }
}

/// Which app a sound or a now-playing item belongs to. Browsers and Electron apps play from
/// helper processes (`com.google.Chrome.helper`, `com.apple.WebKit.GPU`); the user knows the app.
public enum MediaApps {
    /// Players Starnotch can also ask through AppleScript (the fallback when MediaRemote is out).
    public static let scriptable: Set<String> = ["com.spotify.client", "com.apple.Music"]

    /// The app to show: the parent the helper names, else the client, else the process.
    public static func owner(bundleID: String?, clientID: String?, parentID: String?) -> String? {
        for id in [parentID, clientID, bundleID] {
            if let id, !id.isEmpty { return appID(forHelper: id) }
        }
        return nil
    }

    /// `com.google.Chrome.helper.Renderer` → `com.google.Chrome`; WebKit's processes → Safari.
    /// With `running`, a helper maps to the running app whose id it starts with.
    public static func appID(forHelper id: String, running: [String] = []) -> String {
        if id.hasPrefix("com.apple.WebKit") { return "com.apple.Safari" }
        if let app = running.filter({ id != $0 && id.hasPrefix($0 + ".") }).max(by: { $0.count < $1.count }) { return app }
        for marker in [".helper", ".Helper"] {
            if let range = id.range(of: marker) { return String(id[..<range.lowerBound]) }
        }
        return id
    }
}
