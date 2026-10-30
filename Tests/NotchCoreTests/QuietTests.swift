import Testing
import TestSupport
@testable import NotchCore

@Suite struct QuietTests {
    @Test func earsAtRest() {
        // Default: agents merely working don't show; something that needs you does.
        #expect(!Quiet.showsEars(.activity, mode: .attention, watching: false))
        #expect(Quiet.showsEars(.attention, mode: .attention, watching: false))
        #expect(!Quiet.showsEars(.none, mode: .attention, watching: false))
        #expect(Quiet.showsEars(.activity, mode: .always, watching: false))
        #expect(!Quiet.showsEars(.attention, mode: .never, watching: false))
        // Watching: never.
        #expect(!Quiet.showsEars(.attention, mode: .always, watching: true))
    }

    @Test func quietLookTakesOneEar() {
        // Both ears: centred on the notch.
        let both = Quiet.restIsland(notchWidth: 185, ear: 24, oneSided: false)
        #expect(both.width == 233 && both.offset == 0)
        // One ear on the left: one ear wider, shifted left so the right edge stays at the notch's.
        let one = Quiet.restIsland(notchWidth: 185, ear: 24, oneSided: true)
        #expect(one.width == 209 && one.offset == -12)
        #expect(one.offset + one.width / 2 == 185.0 / 2)
        // No room for an ear: just the notch.
        #expect(Quiet.restIsland(notchWidth: 185, ear: 0, oneSided: true) == (185, 0))
    }

    @Test func sneaksWhileWatching() {
        #expect(Quiet.letsThrough(urgent: false, watching: false))
        #expect(!Quiet.letsThrough(urgent: false, watching: true))
        #expect(Quiet.letsThrough(urgent: true, watching: true))
        #expect(Quiet.summary(0) == nil)
        #expect(Quiet.summary(1) == "1 update while you watched")
        #expect(Quiet.summary(3) == "3 updates while you watched")
    }

    @Test func whenToWatch() {
        let now = UTC.date("2026-10-22 20:00")
        #expect(Quiet.watching(manualUntil: nil, manualOn: false, automatic: true, fullscreen: true, videoPlaying: false, now: now))
        #expect(Quiet.watching(manualUntil: nil, manualOn: false, automatic: true, fullscreen: false, videoPlaying: true, now: now))
        #expect(!Quiet.watching(manualUntil: nil, manualOn: false, automatic: false, fullscreen: true, videoPlaying: true, now: now))
        #expect(Quiet.watching(manualUntil: UTC.date("2026-10-22 21:00"), manualOn: true, automatic: false,
                               fullscreen: false, videoPlaying: false, now: now))
        #expect(!Quiet.watching(manualUntil: UTC.date("2026-10-22 19:00"), manualOn: true, automatic: false,
                                fullscreen: false, videoPlaying: false, now: now))
        #expect(Quiet.watching(manualUntil: nil, manualOn: true, automatic: false, fullscreen: false, videoPlaying: false, now: now))
        // Switched off by hand while a video keeps it on: stays off.
        #expect(!Quiet.watching(manualUntil: nil, manualOn: false, automatic: true, fullscreen: false, videoPlaying: true,
                                dismissed: true, now: now))
    }

    @Test func fullscreenWindow() {
        let screen = Bytes.rect(0, 0, 1512, 982)
        #expect(Quiet.fills(window: Bytes.rect(0, 0, 1512, 982), screen: screen))
        #expect(!Quiet.fills(window: Bytes.rect(0, 33, 1512, 949), screen: screen))  // a maximised window below the menu bar
    }
}
