import Foundation

/// Volume per app: which apps make sound right now, and the level the user gave each. The audio
/// itself runs through CoreAudio process taps in the app (`AppVolumeMixer`); this is the logic
/// that needs no audio hardware.
public enum AppVolume {
    /// Below 100 % turns an app down, 0 mutes it, above 100 % boosts a quiet one (clipped).
    public static let range: ClosedRange<Double> = 0...1.5

    /// One audio process as CoreAudio lists it.
    public struct Process: Equatable, Sendable {
        public var objectID: UInt32
        public var pid: Int32
        public var bundleID: String
        public var isPlaying: Bool

        public init(objectID: UInt32, pid: Int32, bundleID: String, isPlaying: Bool) {
            self.objectID = objectID
            self.pid = pid
            self.bundleID = bundleID
            self.isPlaying = isPlaying
        }
    }

    /// One row of the mixer: an app and all its audio processes (a browser's helpers included).
    public struct App: Equatable, Sendable, Identifiable {
        public var id: String { bundleID }
        public var bundleID: String
        public var objectIDs: [UInt32]
        public var isPlaying: Bool

        public init(bundleID: String, objectIDs: [UInt32], isPlaying: Bool) {
            self.bundleID = bundleID
            self.objectIDs = objectIDs
            self.isPlaying = isPlaying
        }
    }

    /// Groups processes by the app the user knows; helpers join their app. Apps that play come
    /// first, then those with a level set (so a muted app stays reachable), by bundle id within.
    /// `running` are the bundle ids of the regular apps; processes of no app (daemons) are left
    /// out, and so is `own` (Starnotch itself).
    public static func apps(_ processes: [Process], running: [String], adjusted: Set<String> = [], own: String? = nil) -> [App] {
        let runningSet = Set(running)
        var byApp: [String: App] = [:]
        for process in processes where !process.bundleID.isEmpty {
            let app = MediaApps.appID(forHelper: process.bundleID, running: running)
            guard runningSet.contains(app), app != own else { continue }
            var entry = byApp[app] ?? App(bundleID: app, objectIDs: [], isPlaying: false)
            entry.objectIDs.append(process.objectID)
            entry.isPlaying = entry.isPlaying || process.isPlaying
            byApp[app] = entry
        }
        return byApp.values
            .filter { $0.isPlaying || adjusted.contains($0.bundleID) }
            .sorted { ($0.isPlaying ? 0 : 1, $0.bundleID) < ($1.isPlaying ? 0 : 1, $1.bundleID) }
    }

    /// For an output channel, the tapped channel that feeds it: stereo goes to the first two,
    /// mono to every channel; extra outputs (surround) stay silent. Nil: silent.
    public static func source(forOutput channel: Int, inputChannels: Int) -> Int? {
        guard inputChannels > 0 else { return nil }
        if inputChannels == 1 { return 0 }
        return channel < inputChannels ? channel : nil
    }

    /// Which of the aggregate device's input channels carry the tap: the output device's own
    /// inputs (a headset's microphone) come first, the tap's `tapChannels` last. Never the mic.
    public static func tapChannels(inputChannels: Int, tapChannels: Int) -> Range<Int> {
        let total = max(0, inputChannels)
        return (total - min(max(0, tapChannels), total))..<total
    }

    /// The level one sample gets, clipped to full scale.
    @inline(__always)
    public static func apply(_ gain: Float, to sample: Float) -> Float {
        min(1, max(-1, sample * gain))
    }

    /// Levels the user set, by bundle id. 100 % is the default and isn't stored.
    public struct Levels: Codable, Equatable, Sendable {
        public private(set) var values: [String: Double] = [:]

        public init(values: [String: Double] = [:]) {
            for (app, level) in values { set(level, for: app) }
        }

        /// Saved levels go through `set` too: one saved close to 100 % comes back untouched.
        public init(from decoder: Decoder) throws {
            struct Saved: Decodable { var values: [String: Double] }
            self.init(values: try Saved(from: decoder).values)
        }

        public func level(_ app: String) -> Double { values[app] ?? 1 }

        public mutating func set(_ level: Double, for app: String) {
            let clamped = min(AppVolume.range.upperBound, max(AppVolume.range.lowerBound, level))
            // Close to 100 %: back to untouched, so the app runs without a tap (and macOS shows no
            // System Audio Recording for it). A nudge of a few percent is no reason to tap an app.
            values[app] = abs(clamped - 1) < Self.untouched ? nil : clamped
        }

        public var adjusted: Set<String> { Set(values.keys) }

        /// Within this of 100 % a level counts as untouched.
        public static let untouched = 0.06
    }

    /// "40 %", "Muted".
    public static func label(_ level: Double) -> String {
        level <= 0.001 ? "Muted" : "\(Int((level * 100).rounded())) %"
    }
}
