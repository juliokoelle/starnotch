/// What an agent is doing, in avatar terms. The app maps session status to a mood; the mood
/// picks the best sprite state a character has.
public enum AvatarMood: String, CaseIterable, Sendable {
    /// Busy and editing files.
    case working
    /// Busy with a tool (shell, search, read, web, subagent).
    case thinking
    /// Busy writing its answer.
    case typing
    /// Finished its turn, waiting for the user.
    case yourTurn
    case failed
    case idle
    /// Idle for a long while.
    case asleep
    /// Just finished (shown for a few seconds, then idle).
    case finished
    /// Dictation is listening.
    case listening
    /// Music is playing (headphones on).
    case music
}

public enum AvatarStates {
    /// Preferred sprite states per mood, best first. A character pack names its states freely;
    /// these are the names the app looks for (see docs/CHARACTER_PACKS.md).
    public static let candidates: [AvatarMood: [String]] = [
        .working: ["focus_working", "working", "thinking", "idle"],
        .thinking: ["thinking", "search_research", "reply_typing", "working", "idle"],
        .typing: ["reply_typing", "thinking", "working", "idle"],
        .yourTurn: ["curious", "alert_important", "surprised", "idle"],
        .failed: ["sad", "error_problem", "surprised", "idle"],
        // Closed eyes.
        .idle: ["sleepy", "sleeping", "shy", "sleep_rest", "idle"],
        .asleep: ["sleeping", "sleep_rest", "sleepy", "idle"],
        .finished: ["celebrating", "download_complete", "happy", "excited", "idle"],
        .listening: ["voice_listening", "music_playback", "music", "idle"],
        // Headphones first (voice_listening); music_playback has none.
        .music: ["voice_listening", "music_playback", "music", "happy", "idle"],
    ]

    /// The best state the character has for `mood`, else `idle`, else any state; `nil` when
    /// the character has no state sprites (then the app shows its portrait).
    public static func state(for mood: AvatarMood, available: Set<String>) -> String? {
        if let match = candidates[mood]?.first(where: available.contains) { return match }
        if available.contains("idle") { return "idle" }
        return available.min()
    }
}
