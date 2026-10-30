import Foundation

/// What the island shows at rest, and what may interrupt: the rules behind "quiet by default"
/// and Watch mode, without AppKit.
public enum Quiet {
    /// What a module has to show beside the notch at rest.
    public enum Ambient: Int, Comparable, Sendable {
        case none
        /// Something is going on (agents at work, music): shown only with "Always".
        case activity
        /// Something needs the user (waiting for you, a failure, a meeting in 5 min, dictation).
        case attention

        public static func < (a: Ambient, b: Ambient) -> Bool { a.rawValue < b.rawValue }
    }

    /// Ears at rest for this ambient level.
    public static func showsEars(_ ambient: Ambient, mode: EarsMode, watching: Bool) -> Bool {
        if watching { return false }
        switch mode {
        case .never: return false
        case .attention: return ambient == .attention
        case .always: return ambient >= .activity
        }
    }

    /// The island with ears at rest: its width without the flares, and how far its centre sits
    /// from the notch's. Both ears: symmetric. The quiet look (`oneSided`): only the left ear, so
    /// the right edge stays flush with the notch and the island grows by one ear, not two.
    public static func restIsland(notchWidth: CGFloat, ear: CGFloat, oneSided: Bool) -> (width: CGFloat, offset: CGFloat) {
        oneSided ? (notchWidth + ear, -ear / 2) : (notchWidth + 2 * ear, 0)
    }

    /// While watching, only urgent sneaks get through; the rest are counted for the summary.
    public static func letsThrough(urgent: Bool, watching: Bool) -> Bool { !watching || urgent }

    /// "3 updates while you watched".
    public static func summary(_ count: Int) -> String? {
        count > 0 ? "\(count) update\(count == 1 ? "" : "s") while you watched" : nil
    }

    /// Watch mode from what is on screen: a fullscreen app on the notch display, or video
    /// keeping the display awake for the frontmost app; plus the manual toggle. `dismissed`: the
    /// user switched an automatic Watch mode off, which holds until the fullscreen app or video ends.
    public static func watching(manualUntil: Date?, manualOn: Bool, automatic: Bool, fullscreen: Bool,
                                videoPlaying: Bool, dismissed: Bool = false, now: Date) -> Bool {
        if manualOn, manualUntil.map({ now < $0 }) ?? true { return true }
        return automatic && (fullscreen || videoPlaying) && !dismissed
    }

    /// A window fills the whole screen (fullscreen Space): its bounds equal the display's,
    /// menu bar area included, within a point.
    public static func fills(window: CGRect, screen: CGRect) -> Bool {
        abs(window.minX - screen.minX) <= 1 && abs(window.minY - screen.minY) <= 1
            && abs(window.width - screen.width) <= 1 && abs(window.height - screen.height) <= 1
    }
}
