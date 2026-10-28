import Foundation
import NotchCore

/// Synced lyrics from LRCLIB, cached on disk (`~/Library/Caches/<app>/Lyrics`, one small JSON
/// per track) so a track is asked for once. Only while the Synced lyrics tool is on; the request
/// carries title, artist, album and duration, nothing about the user.
@MainActor
final class LyricsStore {
    private var memory: [String: LyricsCacheEntry] = [:]
    private var asking: [String: Task<SyncedLyrics?, Never>] = [:]

    static let folder: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: Brand.supportFolderName).appending(path: "Lyrics")

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        // LRCLIB asks clients to name themselves.
        configuration.httpAdditionalHeaders = ["User-Agent": "\(Brand.name) (macOS notch app)"]
        return URLSession(configuration: configuration)
    }()

    /// Cached lyrics right away, without asking the network (nil when not cached or none).
    func cached(_ query: LRCLIB.Query) -> SyncedLyrics? {
        entry(query.cacheKey)?.lyrics
    }

    func lyrics(for query: LRCLIB.Query) async -> SyncedLyrics? {
        guard query.isSearchable else { return nil }
        let key = query.cacheKey
        if let entry = entry(key), entry.isFresh(at: Date()) { return entry.lyrics }
        if let running = asking[key] { return await running.value }
        let task = Task<SyncedLyrics?, Never> { [weak self] in
            let result = await Self.fetch(query)
            // Busy or offline: don't remember a miss, try again next time.
            guard let result else { return nil }
            self?.store(LyricsCacheEntry(lyrics: result.lyrics, fetched: Date()), key: key)
            return result.lyrics
        }
        asking[key] = task
        let lyrics = await task.value
        asking[key] = nil
        return lyrics
    }

    private func entry(_ key: String) -> LyricsCacheEntry? {
        if let entry = memory[key] { return entry }
        let file = Self.folder.appending(path: "\(key).json")
        guard let data = try? Data(contentsOf: file),
              let entry = try? JSONDecoder().decode(LyricsCacheEntry.self, from: data) else { return nil }
        memory[key] = entry
        return entry
    }

    private func store(_ entry: LyricsCacheEntry, key: String) {
        memory[key] = entry
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entry) {
            try? data.write(to: Self.folder.appending(path: "\(key).json"), options: .atomic)
        }
    }

    private struct Answer: Sendable { var lyrics: SyncedLyrics? }

    /// `/get`, then `/search` when it finds nothing. Nil when LRCLIB couldn't answer (offline,
    /// busy); an answer without lyrics when it has none for this track.
    private nonisolated static func fetch(_ query: LRCLIB.Query) async -> Answer? {
        guard let (data, response) = try? await session.data(from: LRCLIB.getURL(query)),
              let status = (response as? HTTPURLResponse)?.statusCode else { return nil }
        if status == 200, let lyrics = LRCLIB.lyrics(fromGet: data) { return Answer(lyrics: lyrics) }
        guard status == 200 || status == 404 else { return nil }
        guard let (found, searchResponse) = try? await session.data(from: LRCLIB.searchURL(query)),
              (searchResponse as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return Answer(lyrics: LRCLIB.lyrics(fromSearch: found, duration: query.duration))
    }
}
