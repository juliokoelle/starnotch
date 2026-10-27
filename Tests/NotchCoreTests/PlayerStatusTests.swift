import Testing
@testable import NotchCore

@Suite struct PlayerStatusTests {
    @Test func spotify() throws {
        let status = try #require(PlayerStatus.parse("playing||Low Tide||Ola Brenn||214000||47,5||https://i.scdn.co/image/ab67||spotify:track:1", source: .spotify))
        #expect(status.isPlaying)
        #expect(status.duration == 214)
        #expect(status.position == 47.5)
        #expect(status.artworkURL?.host == "i.scdn.co")
        #expect(status.trackID == "spotify:track:1")
        #expect(status.album.isEmpty)
    }

    @Test func album() throws {
        let status = try #require(PlayerStatus.parse("playing||Low Tide||Ola Brenn||214000||1||||spotify:track:1||Harbour Lights ", source: .spotify))
        #expect(status.album == "Harbour Lights")
        #expect(status.trackID == "spotify:track:1")
    }

    @Test func music() throws {
        let status = try #require(PlayerStatus.parse("paused||Glass Harbour||Nuri Kaas||188.4||12||||ABCD1234", source: .music))
        #expect(!status.isPlaying)
        #expect(status.duration == 188.4)
        #expect(status.artworkURL == nil)
        #expect(status.trackID == "ABCD1234")
    }

    @Test func stoppedOrBroken() {
        #expect(PlayerStatus.parse("stopped", source: .music) == nil)
        #expect(PlayerStatus.parse("playing||||x||1||1||||", source: .spotify) == nil)
        #expect(PlayerStatus.parse("garbage", source: .spotify) == nil)
        // Missing id: title and artist identify the track.
        #expect(PlayerStatus.parse("playing||A||B||10||1||||", source: .music)?.trackID == "A|B")
    }
}
