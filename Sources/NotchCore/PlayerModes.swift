import Foundation

/// Shuffle, repeat and favorite of the player behind Now Playing, as Spotify or Music report
/// them through AppleScript in one `||`-separated line: `shuffle||repeat||favorite`. Spotify
/// repeats the playlist or nothing (no single song) and has no favorite to script; what a player
/// doesn't have stays nil and its button hidden.
public struct PlayerModes: Equatable, Sendable {
    public enum Repeat: String, Sendable { case off, all, one }

    /// The buttons beside the transport.
    public enum Control: Sendable { case shuffle, repeatMode, favorite }

    public var shuffle: Bool
    public var repeatMode: Repeat
    /// The current track is a favorite (Music's star); nil where the player can't say (Spotify,
    /// a radio stream).
    public var favorite: Bool?

    public init(shuffle: Bool = false, repeatMode: Repeat = .off, favorite: Bool? = nil) {
        self.shuffle = shuffle
        self.repeatMode = repeatMode
        self.favorite = favorite
    }

    /// Before macOS was asked whether the app may control the player: the buttons show as off
    /// and the first click lets macOS ask.
    public static func unknown(_ source: PlayerStatus.Source) -> PlayerModes {
        PlayerModes(favorite: source == .music ? false : nil)
    }

    /// `nil` for a stopped player or a reply that isn't one.
    public static func parse(_ reply: String, source: PlayerStatus.Source) -> PlayerModes? {
        let parts = reply.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: PlayerStatus.separator)
        guard parts.count >= 2, let shuffle = Bool(parts[0]) else { return nil }
        let repeatMode: Repeat
        switch source {
        case .spotify:
            guard let on = Bool(parts[1]) else { return nil }
            repeatMode = on ? .all : .off
        case .music:
            guard let mode = Repeat(rawValue: parts[1]) else { return nil }
            repeatMode = mode
        }
        let favorite = source == .music && parts.count > 2 ? Bool(parts[2]) : nil
        return PlayerModes(shuffle: shuffle, repeatMode: repeatMode, favorite: favorite)
    }

    /// What a click makes of it, shown before the player answers: shuffle and favorite flip;
    /// Music repeats off → all → one → off like its own button, Spotify off ↔ all.
    public func toggled(_ control: Control, source: PlayerStatus.Source) -> PlayerModes {
        var next = self
        switch control {
        case .shuffle: next.shuffle.toggle()
        case .favorite: next.favorite = favorite.map { !$0 }
        case .repeatMode:
            switch (repeatMode, source) {
            case (.off, _): next.repeatMode = .all
            case (.all, .music): next.repeatMode = .one
            default: next.repeatMode = .off
            }
        }
        return next
    }

    /// Reads the modes; with `toggle`, flips one in the player first. One round trip, and the
    /// reply is what the player ended up with (also when the button showed an old state). The
    /// favorite only flips on `track`, the song the click was for: macOS's dialog can be up while
    /// the next one starts, and then nothing changes. Without `track` it doesn't flip at all.
    public static func script(for source: PlayerStatus.Source, toggle: Control? = nil,
                              track: (title: String, artist: String)? = nil) -> String {
        switch source {
        case .spotify:
            let change = switch toggle {
            case .shuffle: "set shuffling to not shuffling"
            case .repeatMode: "set repeating to not repeating"
            case .favorite, nil: ""
            }
            return """
            tell application "Spotify"
                if player state is stopped then return ""
                \(change)
                return (shuffling as string) & "||" & (repeating as string) & "||"
            end tell
            """
        case .music:
            // «class pLov» is the track's favorite: `favorited` since macOS 14.1, `loved` before.
            let change = switch toggle {
            case .shuffle: "set shuffle enabled to not shuffle enabled"
            case .repeatMode: """
                if song repeat is off then
                    set song repeat to all
                else if song repeat is all then
                    set song repeat to one
                else
                    set song repeat to off
                end if
                """
            case .favorite:
                // `t` is that song itself, not whatever plays a moment later.
                if let track {
                    """
                    try
                        set t to current track
                        if name of t is \(literal(track.title)) and artist of t is \(literal(track.artist)) then set «class pLov» of t to not («class pLov» of t)
                    end try
                    """
                } else {
                    ""
                }
            case nil: ""
            }
            return """
            tell application "Music"
                if player state is stopped then return ""
                \(change)
                set f to ""
                try
                    set f to («class pLov» of current track) as string
                end try
                return (shuffle enabled as string) & "||" & (song repeat as string) & "||" & f
            end tell
            """
        }
    }

    /// `text` as an AppleScript string, quotes and backslashes escaped: a title can't end it early.
    static func literal(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Whether the app may send the player Apple Events, from `AEDeterminePermissionToAutomateTarget`
    /// asked without a dialog.
    public enum Access: Equatable, Sendable {
        case allowed
        /// macOS hasn't asked yet; it asks on the first click.
        case notAsked
        /// Declined in System Settings, or the player isn't running.
        case unavailable
    }

    public static func access(_ status: Int32) -> Access {
        switch status {
        case 0: .allowed
        case -1744: .notAsked  // errAEEventWouldRequireUserConsent
        default: .unavailable  // errAEEventNotPermitted (-1743), procNotFound (-600)
        }
    }
}
