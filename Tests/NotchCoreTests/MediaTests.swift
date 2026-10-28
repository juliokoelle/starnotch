import Foundation
import Testing
@testable import NotchCore

@Suite struct MediaSnapshotTests {
    @Test func browserTrackBelongsToTheBrowser() throws {
        let line = #"{"title":"Live at the Pier","artist":"Ola Brenn","album":"","duration":200.5,"elapsed":12,"rate":1,"playing":true,"timestamp":1800000000,"bundleID":"com.google.Chrome.helper","clientID":"com.google.Chrome"}"#
        guard case .playing(let snapshot)? = MediaSnapshot.parse(Data(line.utf8)) else { Issue.record("no track"); return }
        #expect(snapshot.appID == "com.google.Chrome")
        #expect(snapshot.title == "Live at the Pier")
        #expect(snapshot.duration == 200.5)
        #expect(snapshot.isPlaying)
        #expect(snapshot.artwork == nil)
        // 10 s after the report, playing at normal speed.
        #expect(snapshot.position(at: Date(timeIntervalSince1970: 1_800_000_010)) == 22)
    }

    @Test func safariPlaysThroughWebKit() throws {
        let line = #"{"title":"A","bundleID":"com.apple.WebKit.GPU","parentID":"com.apple.Safari","playing":false}"#
        guard case .playing(let snapshot)? = MediaSnapshot.parse(Data(line.utf8)) else { Issue.record("no track"); return }
        #expect(snapshot.appID == "com.apple.Safari")
        #expect(!snapshot.isPlaying)
    }

    @Test func pausedPositionStaysAndClampsToTheEnd() {
        let paused = MediaSnapshot(appID: "x", title: "t", duration: 100, elapsed: 40, timestamp: Date(timeIntervalSince1970: 0), isPlaying: false)
        #expect(paused.position(at: Date(timeIntervalSince1970: 1000)) == 40)
        let playing = MediaSnapshot(appID: "x", title: "t", duration: 100, elapsed: 90, timestamp: Date(timeIntervalSince1970: 0))
        #expect(playing.position(at: Date(timeIntervalSince1970: 60)) == 100)
    }

    @Test func artworkComesAsBase64() throws {
        let line = #"{"title":"A","bundleID":"com.spotify.client","artwork":"AAEC"}"#
        guard case .playing(let snapshot)? = MediaSnapshot.parse(Data(line.utf8)) else { Issue.record("no track"); return }
        #expect(snapshot.artwork == Data([0, 1, 2]))
        #expect(snapshot.trackKey == "com.spotify.client|A||")
    }

    @Test func theNextTrackOfAnAlbumKeepsTheCover() throws {
        // The helper sends the cover's data once; the next track with the same cover only names it.
        let first = #"{"title":"Track One","album":"Album","bundleID":"com.apple.Music","artwork":"AAEC","artworkHash":"5f2"}"#
        let second = #"{"title":"Track Two","album":"Album","bundleID":"com.apple.Music","artworkHash":"5f2"}"#
        let other = #"{"title":"Elsewhere","bundleID":"com.apple.Music","artworkHash":"9a0"}"#
        var artwork = MediaArtwork()
        guard case .playing(let one)? = MediaSnapshot.parse(Data(first.utf8)),
              case .playing(let two)? = MediaSnapshot.parse(Data(second.utf8)),
              case .playing(let three)? = MediaSnapshot.parse(Data(other.utf8)) else { Issue.record("no track"); return }
        artwork.remember(one)
        artwork.remember(two)
        #expect(one.trackKey != two.trackKey)
        #expect(artwork.artwork(for: one) == Data([0, 1, 2]))
        #expect(artwork.artwork(for: two) == Data([0, 1, 2]))
        // A cover not sent yet isn't the old one.
        #expect(artwork.artwork(for: three) == nil)
        #expect(artwork.artwork(for: MediaSnapshot(appID: "x", title: "No cover")) == nil)
    }

    @Test func nothingAndNoise() {
        #expect(MediaSnapshot.parse(Data(#"{"title":""}"#.utf8)) == .nothing)
        #expect(MediaSnapshot.parse(Data("MediaRemote not available".utf8)) == nil)
    }

    @Test func helpersMapToTheirApp() {
        #expect(MediaApps.appID(forHelper: "com.google.Chrome.helper.Renderer") == "com.google.Chrome")
        #expect(MediaApps.appID(forHelper: "com.apple.WebKit.WebContent") == "com.apple.Safari")
        #expect(MediaApps.appID(forHelper: "com.tinyspeck.slackmacgap.helper", running: ["com.tinyspeck.slackmacgap"]) == "com.tinyspeck.slackmacgap")
        #expect(MediaApps.appID(forHelper: "org.videolan.vlc") == "org.videolan.vlc")
    }
}

@Suite struct LyricsTests {
    let lrc = """
    [ar:Ola Brenn]
    [00:01.50] First light
    [00:05.00][01:00.00] Chorus line
    [00:09.25]
    plain text without a time
    [00:12,5] Comma decimal
    """

    @Test func parsesTimedLinesOnly() throws {
        let lyrics = try #require(SyncedLyrics.parse(lrc))
        #expect(lyrics.lines.map(\.time) == [1.5, 5, 9.25, 12.5, 60])
        #expect(lyrics.lines.first?.text == "First light")
        #expect(SyncedLyrics.parse("[ar:x]\nno times") == nil)
    }

    @Test func currentLineFollowsThePosition() throws {
        let lyrics = try #require(SyncedLyrics.parse(lrc))
        #expect(lyrics.line(at: 0) == nil)
        #expect(lyrics.line(at: 1.5) == "First light")
        #expect(lyrics.line(at: 7) == "Chorus line")
        // An empty line is an instrumental gap.
        #expect(lyrics.line(at: 10) == nil)
        #expect(lyrics.index(at: 10) == 2)
        #expect(lyrics.line(at: 300) == "Chorus line")
    }

    @Test func lrclibURLs() {
        let query = LRCLIB.Query(title: "Low Tide", artist: "Ola Brenn", album: "Night Ferries", duration: 213.6)
        let get = LRCLIB.getURL(query).absoluteString
        #expect(get.hasPrefix("https://lrclib.net/api/get?"))
        #expect(get.contains("track_name=Low%20Tide"))
        #expect(get.contains("album_name=Night%20Ferries"))
        #expect(get.contains("duration=214"))
        #expect(LRCLIB.searchURL(query).absoluteString.contains("/api/search?"))
        #expect(!LRCLIB.Query(title: "A video", artist: "").isSearchable)
        #expect(query.cacheKey == LRCLIB.Query(title: "low tide", artist: "OLA BRENN", album: "night ferries", duration: 214).cacheKey)
    }

    @Test func picksTheSearchResultWithTheRightLength() {
        let json = #"[{"duration":180,"syncedLyrics":"[00:01.00] Short cut"},{"duration":214,"syncedLyrics":"[00:01.00] Album cut"},{"duration":214,"syncedLyrics":null}]"#
        #expect(LRCLIB.lyrics(fromSearch: Data(json.utf8), duration: 213)?.lines.first?.text == "Album cut")
        #expect(LRCLIB.lyrics(fromSearch: Data(json.utf8), duration: 300) == nil)
        #expect(LRCLIB.lyrics(fromGet: Data(#"{"syncedLyrics":"[00:02.00] Hi"}"#.utf8))?.lines.count == 1)
        #expect(LRCLIB.lyrics(fromGet: Data(#"{"instrumental":true,"syncedLyrics":null}"#.utf8)) == nil)
    }

    @Test func missesAreAskedAgainLater() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let miss = LyricsCacheEntry(lyrics: nil, fetched: t0)
        #expect(miss.isFresh(at: t0.addingTimeInterval(3600)))
        #expect(!miss.isFresh(at: t0.addingTimeInterval(LyricsCacheEntry.retryAfter + 1)))
        let hit = LyricsCacheEntry(lyrics: SyncedLyrics(lines: [.init(time: 1, text: "a")]), fetched: t0)
        #expect(hit.isFresh(at: t0.addingTimeInterval(365 * 86_400)))
    }
}

@Suite struct AppVolumeTests {
    @Test func processesGroupByApp() {
        let processes = [
            AppVolume.Process(objectID: 1, pid: 10, bundleID: "com.google.Chrome.helper", isPlaying: true),
            AppVolume.Process(objectID: 2, pid: 11, bundleID: "com.google.Chrome", isPlaying: false),
            AppVolume.Process(objectID: 3, pid: 12, bundleID: "com.spotify.client", isPlaying: false),
            AppVolume.Process(objectID: 4, pid: 13, bundleID: "com.apple.audio.coreaudiod", isPlaying: true),
            AppVolume.Process(objectID: 5, pid: 14, bundleID: "app.starnotch.mac", isPlaying: true),
        ]
        let running = ["com.google.Chrome", "com.spotify.client", "app.starnotch.mac"]
        let apps = AppVolume.apps(processes, running: running, own: "app.starnotch.mac")
        #expect(apps.map(\.bundleID) == ["com.google.Chrome"])
        #expect(apps.first?.objectIDs == [1, 2])
        // A muted app stays in the list though it makes no sound.
        let withMuted = AppVolume.apps(processes, running: running, adjusted: ["com.spotify.client"], own: "app.starnotch.mac")
        #expect(withMuted.map(\.bundleID) == ["com.google.Chrome", "com.spotify.client"])
    }

    @Test func channelsMapStereoAndMono() {
        #expect(AppVolume.source(forOutput: 0, inputChannels: 2) == 0)
        #expect(AppVolume.source(forOutput: 1, inputChannels: 2) == 1)
        #expect(AppVolume.source(forOutput: 4, inputChannels: 2) == nil)
        #expect(AppVolume.source(forOutput: 3, inputChannels: 1) == 0)
        #expect(AppVolume.source(forOutput: 0, inputChannels: 0) == nil)
    }

    @Test func gainClipsAtFullScale() {
        #expect(AppVolume.apply(0.5, to: 0.8) == 0.4)
        #expect(AppVolume.apply(1.5, to: 0.9) == 1)
        #expect(AppVolume.apply(1.5, to: -0.9) == -1)
    }

    @Test func levelsForgetOneHundredPercent() {
        var levels = AppVolume.Levels()
        levels.set(0.4, for: "a")
        levels.set(9, for: "b")
        levels.set(1.01, for: "c")
        #expect(levels.level("a") == 0.4)
        #expect(levels.level("b") == AppVolume.range.upperBound)
        #expect(levels.level("c") == 1)
        #expect(levels.adjusted == ["a", "b"])
        #expect(AppVolume.label(0) == "Muted")
        #expect(AppVolume.label(0.4) == "40 %")
    }
}

@Suite struct HelperProcessTests {
    @Test func failuresCountShortRunsEvenWithLines() {
        var restarts = HelperRestarts()
        #expect(restarts.ended(after: 1))
        #expect(restarts.ended(after: 5))
        #expect(!restarts.ended(after: 2))
        #expect(restarts.gaveUp)
        // A run that lasted starts the count over.
        var lasting = HelperRestarts()
        #expect(lasting.ended(after: 1))
        #expect(lasting.ended(after: 2))
        #expect(lasting.ended(after: 600))
        #expect(lasting.failures == 1)
        lasting.failedToStart()
        #expect(lasting.gaveUp)
    }

    @Test func linesThenOneExitFromAHelperThatEnds() async throws {
        final class Seen: @unchecked Sendable {
            let lock = NSLock()
            var lines: [String] = []
            var exits: [Int32] = []
        }
        let seen = Seen()
        let queue = DispatchQueue(label: "test.lines")
        // One line split across two writes, a last line without its newline, then exit 2.
        let helper = LineProcess(executable: URL(fileURLWithPath: "/bin/sh"),
                                 arguments: ["-c", #"printf '{"title":'; sleep 0.1; printf '"A"}\nlast'; exit 2"#])
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            do {
                try helper.start(queue: queue, onLine: { line in
                    seen.lock.withLock { seen.lines.append(String(decoding: line, as: UTF8.self)) }
                }, onExit: { status in
                    seen.lock.withLock { seen.exits.append(status) }
                    done.resume()
                })
            } catch {
                done.resume(throwing: error)
            }
        }
        // Long enough for a handler stuck at the end of output to pile up callbacks.
        try await Task.sleep(for: .milliseconds(300))
        seen.lock.withLock {
            #expect(seen.lines == [#"{"title":"A"}"#, "last"])
            #expect(seen.exits == [2])
        }
    }

    @Test func splitKeepsTheUnfinishedLine() {
        var buffer = Data("one\ntwo\nthr".utf8)
        #expect(LineProcess.split(&buffer) == [Data("one".utf8), Data("two".utf8)])
        #expect(buffer == Data("thr".utf8))
    }
}
