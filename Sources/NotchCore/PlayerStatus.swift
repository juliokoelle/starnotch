import Foundation

/// What Spotify or Music reports through AppleScript, one `||`-separated line:
/// `state||title||artist||duration||position||artworkURL||id`.
public struct PlayerStatus: Equatable, Sendable {
    public enum Source: String, Sendable { case spotify, music }

    public var source: Source
    public var isPlaying: Bool
    public var title: String
    public var artist: String
    /// Seconds.
    public var duration: Double
    public var position: Double
    public var artworkURL: URL?
    public var trackID: String

    public static let separator = "||"

    /// `nil` for "stopped", an empty title, or a malformed reply.
    public static func parse(_ reply: String, source: Source) -> PlayerStatus? {
        let parts = reply.components(separatedBy: separator)
        guard parts.count >= 7, parts[0] != "stopped" else { return nil }
        let title = parts[1].trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        func number(_ s: String) -> Double { Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }
        // Spotify reports the duration in milliseconds, Music in seconds.
        let duration = source == .spotify ? number(parts[3]) / 1000 : number(parts[3])
        return PlayerStatus(
            source: source,
            isPlaying: parts[0] == "playing",
            title: title,
            artist: parts[2],
            duration: duration,
            position: number(parts[4]),
            artworkURL: URL(string: parts[5]).flatMap { $0.scheme == "https" ? $0 : nil },
            trackID: parts[6].isEmpty ? "\(title)|\(parts[2])" : parts[6]
        )
    }
}
