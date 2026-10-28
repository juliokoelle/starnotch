import Foundation

/// Time-synced lyrics from an LRC text (`[01:02.34] A line`), as LRCLIB serves them.
public struct SyncedLyrics: Equatable, Sendable, Codable {
    public struct Line: Equatable, Sendable, Codable {
        /// Seconds from the start of the track.
        public var time: Double
        /// Empty for an instrumental gap.
        public var text: String

        public init(time: Double, text: String) {
            self.time = time
            self.text = text
        }
    }

    /// Sorted by time.
    public var lines: [Line]

    public init(lines: [Line]) { self.lines = lines.sorted { $0.time < $1.time } }

    /// Parses LRC; lines without a time tag (`[ar:…]` metadata, plain text) are skipped. A line
    /// with several tags (`[00:12.00][01:30.00] Chorus`) appears once per tag. Nil without lines.
    public static func parse(_ lrc: String) -> SyncedLyrics? {
        var lines: [Line] = []
        for raw in lrc.split(whereSeparator: \.isNewline) {
            var rest = Substring(raw)
            var times: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                guard let time = Self.time(tag) else { break }
                times.append(time)
                rest = rest[rest.index(after: close)...]
            }
            let text = rest.trimmingCharacters(in: .whitespaces)
            for time in times { lines.append(Line(time: time, text: text)) }
        }
        return lines.isEmpty ? nil : SyncedLyrics(lines: lines)
    }

    /// `mm:ss.xx` or `mm:ss`.
    static func time(_ tag: Substring) -> Double? {
        let parts = tag.split(separator: ":")
        guard parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1].replacingOccurrences(of: ",", with: ".")),
              minutes >= 0, seconds >= 0 else { return nil }
        return minutes * 60 + seconds
    }

    /// The index of the line sung at `position`, nil before the first.
    public func index(at position: Double) -> Int? {
        // Binary search for the last line whose time is <= position.
        var low = 0, high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if lines[mid].time <= position { low = mid + 1 } else { high = mid }
        }
        return low == 0 ? nil : low - 1
    }

    /// The text sung at `position`; nil before the first line and in instrumental gaps.
    public func line(at position: Double) -> String? {
        guard let index = index(at: position) else { return nil }
        let text = lines[index].text
        return text.isEmpty ? nil : text
    }
}

/// LRCLIB (lrclib.net): free, no key. The tool asks it with title, artist, album and duration,
/// nothing else, and only while the user has switched synced lyrics on.
public enum LRCLIB {
    public static let base = URL(string: "https://lrclib.net/api")!

    public struct Query: Equatable, Sendable, Hashable {
        public var title: String
        public var artist: String
        public var album: String
        /// Seconds.
        public var duration: Double

        public init(title: String, artist: String, album: String = "", duration: Double = 0) {
            self.title = title
            self.artist = artist
            self.album = album
            self.duration = duration
        }

        /// Stable across launches: the cache file's name.
        public var cacheKey: String {
            var hash: UInt64 = 0xcbf29ce484222325  // FNV-1a
            for byte in "\(title.lowercased())|\(artist.lowercased())|\(album.lowercased())|\(Int(duration.rounded()))".utf8 {
                hash = (hash ^ UInt64(byte)) &* 0x100000001b3
            }
            return String(hash, radix: 16)
        }

        /// Videos and podcasts rarely have an artist: without one, no lookup.
        public var isSearchable: Bool {
            !title.trimmingCharacters(in: .whitespaces).isEmpty && !artist.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// The exact lookup: `/get` with every field LRCLIB matches on.
    public static func getURL(_ query: Query) -> URL {
        var items = [URLQueryItem(name: "track_name", value: query.title), URLQueryItem(name: "artist_name", value: query.artist)]
        if !query.album.isEmpty { items.append(URLQueryItem(name: "album_name", value: query.album)) }
        if query.duration > 0 { items.append(URLQueryItem(name: "duration", value: String(Int(query.duration.rounded())))) }
        return base.appending(path: "get").appending(queryItems: items)
    }

    /// The fallback when `/get` finds nothing: a search by title and artist.
    public static func searchURL(_ query: Query) -> URL {
        base.appending(path: "search").appending(queryItems: [
            URLQueryItem(name: "track_name", value: query.title), URLQueryItem(name: "artist_name", value: query.artist),
        ])
    }

    public struct Record: Decodable, Equatable, Sendable {
        public var duration: Double?
        public var instrumental: Bool?
        public var syncedLyrics: String?
    }

    /// The lyrics in a `/get` reply.
    public static func lyrics(fromGet data: Data) -> SyncedLyrics? {
        (try? JSONDecoder().decode(Record.self, from: data)).flatMap { $0.syncedLyrics }.flatMap(SyncedLyrics.parse)
    }

    /// The best `/search` result: synced, and its length within a few seconds of the track's.
    public static func lyrics(fromSearch data: Data, duration: Double) -> SyncedLyrics? {
        guard let records = try? JSONDecoder().decode([Record].self, from: data) else { return nil }
        let synced = records.filter { $0.syncedLyrics?.isEmpty == false }
        let fitting = duration > 0 ? synced.filter { abs(($0.duration ?? duration) - duration) <= 4 } : synced
        let best = fitting.min { abs(($0.duration ?? duration) - duration) < abs(($1.duration ?? duration) - duration) }
        return best?.syncedLyrics.flatMap(SyncedLyrics.parse)
    }
}

/// What the lyrics cache keeps per track: the lyrics, or that there are none (asked again after
/// a few days, since LRCLIB grows).
public struct LyricsCacheEntry: Codable, Equatable, Sendable {
    public var lyrics: SyncedLyrics?
    public var fetched: Date

    public static let retryAfter: TimeInterval = 3 * 86_400

    public init(lyrics: SyncedLyrics?, fetched: Date) {
        self.lyrics = lyrics
        self.fetched = fetched
    }

    /// Lyrics stay good; a miss is worth another try after `retryAfter`.
    public func isFresh(at now: Date) -> Bool { lyrics != nil || now.timeIntervalSince(fetched) < Self.retryAfter }
}
