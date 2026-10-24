import Testing
@testable import NotchCore

@Suite struct AvatarTests {
    // Sprite states as the generated library has them.
    let fullKit: Set<String> = ["idle", "happy", "excited", "curious", "thinking", "surprised", "sad", "shy",
                                  "focus_working", "reply_typing", "voice_listening", "alert_important",
                                  "error_problem", "sleep_rest", "download_complete", "search_research"]
    let trio: Set<String> = ["idle", "happy", "curious", "thinking", "sleepy", "sad", "focus_working",
                             "reply_typing", "voice_listening", "error_problem", "sleep_rest", "download_complete"]
    let cast: Set<String> = ["idle", "running", "jumping", "celebrating", "surprised", "working", "thinking", "music", "sleeping"]

    @Test func fullStateSet() {
        #expect(AvatarStates.state(for: .working, available: fullKit) == "focus_working")
        #expect(AvatarStates.state(for: .thinking, available: fullKit) == "thinking")
        #expect(AvatarStates.state(for: .typing, available: fullKit) == "reply_typing")
        #expect(AvatarStates.state(for: .yourTurn, available: fullKit) == "curious")
        #expect(AvatarStates.state(for: .failed, available: fullKit) == "sad")
        #expect(AvatarStates.state(for: .idle, available: fullKit) == "shy")
        #expect(AvatarStates.state(for: .finished, available: fullKit) == "download_complete")
        #expect(AvatarStates.state(for: .listening, available: fullKit) == "voice_listening")
        #expect(AvatarStates.state(for: .music, available: fullKit) == "voice_listening")
        #expect(AvatarStates.state(for: .music, available: ["idle", "music_playback"]) == "music_playback")
        #expect(AvatarStates.state(for: .music, available: cast) == "music")
    }

    @Test func previewModulesStayOutOfSettings() {
        #expect(!ModuleKind.selectable.contains(.nowPlaying))
        #expect(ModuleKind.selectable.contains(.calendar))
    }

    @Test func originalCastFallsBackToItsOwnNames() {
        #expect(AvatarStates.state(for: .working, available: cast) == "working")
        #expect(AvatarStates.state(for: .yourTurn, available: cast) == "surprised")
        #expect(AvatarStates.state(for: .idle, available: cast) == "sleeping")
        #expect(AvatarStates.state(for: .finished, available: cast) == "celebrating")
        #expect(AvatarStates.state(for: .listening, available: cast) == "music")
        #expect(AvatarStates.state(for: .typing, available: cast) == "thinking")
    }

    @Test func trioAndMissingStates() {
        #expect(AvatarStates.state(for: .idle, available: trio) == "sleepy")
        #expect(AvatarStates.state(for: .finished, available: trio) == "download_complete")
        // A character with only one pose shows it for everything.
        #expect(AvatarStates.state(for: .failed, available: ["waving"]) == "waving")
        #expect(AvatarStates.state(for: .failed, available: ["idle", "waving"]) == "idle")
        #expect(AvatarStates.state(for: .working, available: []) == nil)
    }

    @Test func everyMoodHasCandidates() {
        for mood in AvatarMood.allCases {
            #expect(!(AvatarStates.candidates[mood] ?? []).isEmpty)
        }
    }

}
