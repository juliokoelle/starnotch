import Testing
@testable import NotchCore

@Suite struct PlayerModesTests {
    @Test func musicReportsAllThree() throws {
        let modes = try #require(PlayerModes.parse("true||one||false\n", source: .music))
        #expect(modes.shuffle)
        #expect(modes.repeatMode == .one)
        #expect(modes.favorite == false)
        // A radio stream has no favorite to read: the star hides.
        #expect(PlayerModes.parse("false||all||", source: .music)?.favorite == nil)
    }

    @Test func spotifyRepeatsAPlaylistAndHasNoFavorite() throws {
        let modes = try #require(PlayerModes.parse("false||true||", source: .spotify))
        #expect(!modes.shuffle)
        #expect(modes.repeatMode == .all)
        #expect(modes.favorite == nil)
        #expect(PlayerModes.parse("true||false||true", source: .spotify)?.favorite == nil)
    }

    @Test func stoppedOrBroken() {
        #expect(PlayerModes.parse("", source: .music) == nil)
        #expect(PlayerModes.parse("true", source: .spotify) == nil)
        #expect(PlayerModes.parse("yes||one||", source: .music) == nil)
        // Music's repeat is a mode, Spotify's a switch: neither takes the other's word.
        #expect(PlayerModes.parse("true||true||", source: .music) == nil)
        #expect(PlayerModes.parse("true||one||", source: .spotify) == nil)
    }

    @Test func repeatCyclesLikeThePlayer() {
        let off = PlayerModes()
        // Music: off → all → one → off, as its own button.
        let all = off.toggled(.repeatMode, source: .music)
        #expect(all.repeatMode == .all)
        #expect(all.toggled(.repeatMode, source: .music).repeatMode == .one)
        #expect(all.toggled(.repeatMode, source: .music).toggled(.repeatMode, source: .music).repeatMode == .off)
        // Spotify has no single-song repeat over AppleScript.
        #expect(all.toggled(.repeatMode, source: .spotify).repeatMode == .off)
    }

    @Test func shuffleAndFavoriteFlip() {
        let modes = PlayerModes(shuffle: false, repeatMode: .all, favorite: false)
        #expect(modes.toggled(.shuffle, source: .music).shuffle)
        #expect(modes.toggled(.favorite, source: .music).favorite == true)
        // Without a favorite there's nothing to flip.
        #expect(PlayerModes(favorite: nil).toggled(.favorite, source: .spotify).favorite == nil)
        #expect(modes.toggled(.shuffle, source: .music).repeatMode == .all)
    }

    @Test func notAskedShowsTheButtonsOff() {
        #expect(PlayerModes.unknown(.music) == PlayerModes(shuffle: false, repeatMode: .off, favorite: false))
        #expect(PlayerModes.unknown(.spotify).favorite == nil)
    }

    @Test func scriptsReadAndToggleInOneRoundTrip() {
        let read = PlayerModes.script(for: .music)
        #expect(read.contains("tell application \"Music\""))
        #expect(read.contains("song repeat as string"))
        #expect(!read.contains("set shuffle"))
        #expect(PlayerModes.script(for: .music, toggle: .shuffle).contains("set shuffle enabled to not shuffle enabled"))
        #expect(PlayerModes.script(for: .music, toggle: .favorite, track: ("Song A", "Band")).contains("set «class pLov» of t to not"))
        #expect(PlayerModes.script(for: .spotify, toggle: .repeatMode).contains("set repeating to not repeating"))
        // Spotify can't favorite through AppleScript: the script only reads.
        #expect(PlayerModes.script(for: .spotify, toggle: .favorite) == PlayerModes.script(for: .spotify))
    }

    @Test func theStarOnlyChangesTheSongItWasFor() {
        // The song is checked before anything changes; another one playing by then stays as it is.
        let star = PlayerModes.script(for: .music, toggle: .favorite, track: ("Song A", "Band"))
        #expect(star.contains("set t to current track"))
        #expect(star.contains("if name of t is \"Song A\" and artist of t is \"Band\" then set «class pLov» of t to not («class pLov» of t)"))
        #expect(!star.contains("of current track to"))
        // Without the song, the click changes nothing; the script only reads.
        #expect(PlayerModes.script(for: .music, toggle: .favorite) == PlayerModes.script(for: .music))
        // Quotes and backslashes in a title stay inside its string.
        let odd = PlayerModes.script(for: .music, toggle: .favorite, track: (#"Say "Hi" \" & (do shell script "x") & ""#, "AC/DC"))
        #expect(odd.contains(#"if name of t is "Say \"Hi\" \\\" & (do shell script \"x\") & \"" and artist of t is "AC/DC" then"#))
    }

    @Test func automationAccess() {
        #expect(PlayerModes.access(0) == .allowed)
        #expect(PlayerModes.access(-1744) == .notAsked)
        #expect(PlayerModes.access(-1743) == .unavailable)
        #expect(PlayerModes.access(-600) == .unavailable)
    }
}
