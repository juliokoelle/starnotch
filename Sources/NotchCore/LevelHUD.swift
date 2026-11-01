import Foundation

/// The output volume as the level HUD reads it (Settings › Notch): device, level and mute.
public struct LevelReading: Equatable, Sendable {
    public var device: UInt32
    /// 0 … 1.
    public var level: Double
    public var muted: Bool

    public init(device: UInt32, level: Double, muted: Bool) {
        self.device = device
        self.level = min(1, max(0, level))
        self.muted = muted
    }
}

/// When the volume HUD in the notch shows, and with which speaker. Apple's own HUD can't be hidden
/// with public API (only by unloading OSDUIHelper with SIP off, or by swallowing the volume keys
/// and setting the volume ourselves), so this one shows beside it.
public enum LevelHUD {
    /// Seconds the bar stays after the last change; every change starts it again.
    public static let duration: Double = 1.5

    /// A change the user made: the same output with another level or mute. The first reading and a
    /// new output (headphones plugged in) only set the baseline, as Apple's HUD shows nothing then;
    /// CoreAudio saying the same level twice shows nothing either.
    public static func shows(previous: LevelReading?, next: LevelReading) -> Bool {
        guard let previous, previous.device == next.device else { return false }
        return previous.muted != next.muted || abs(previous.level - next.level) > 0.001
    }

    /// The speaker with as many waves as the level fills thirds; struck through when muted or at 0.
    public static func symbol(_ reading: LevelReading) -> String {
        if reading.muted || reading.level < 0.005 { return "speaker.slash.fill" }
        return reading.level < 0.34 ? "speaker.wave.1.fill" : reading.level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }

    /// What the bar fills: nothing while muted.
    public static func fill(_ reading: LevelReading) -> Double { reading.muted ? 0 : reading.level }
}
