import Testing
@testable import NotchCore

@Suite struct LevelHUDTests {
    let speakers: UInt32 = 86

    @Test func showsWhatTheUserChanged() {
        let half = LevelReading(device: speakers, level: 0.5, muted: false)
        // The first reading and the same level again: nothing.
        #expect(!LevelHUD.shows(previous: nil, next: half))
        #expect(!LevelHUD.shows(previous: half, next: half))
        #expect(LevelHUD.shows(previous: half, next: LevelReading(device: speakers, level: 0.5625, muted: false)))
        #expect(LevelHUD.shows(previous: half, next: LevelReading(device: speakers, level: 0.5, muted: true)))
        // Headphones plugged in: another output, only a new baseline.
        #expect(!LevelHUD.shows(previous: half, next: LevelReading(device: 120, level: 0.25, muted: false)))
    }

    @Test func speakerAndFill() {
        #expect(LevelHUD.symbol(LevelReading(device: speakers, level: 0.8, muted: true)) == "speaker.slash.fill")
        #expect(LevelHUD.symbol(LevelReading(device: speakers, level: 0, muted: false)) == "speaker.slash.fill")
        #expect(LevelHUD.symbol(LevelReading(device: speakers, level: 0.2, muted: false)) == "speaker.wave.1.fill")
        #expect(LevelHUD.symbol(LevelReading(device: speakers, level: 0.5, muted: false)) == "speaker.wave.2.fill")
        #expect(LevelHUD.symbol(LevelReading(device: speakers, level: 1, muted: false)) == "speaker.wave.3.fill")
        #expect(LevelHUD.fill(LevelReading(device: speakers, level: 0.8, muted: true)) == 0)
        // Out-of-range levels are clamped.
        #expect(LevelReading(device: speakers, level: 1.4, muted: false).level == 1)
    }
}
