/// Notch apps the settings window suggests first. Matched by name or bundle identifier,
/// because bundle identifiers differ between editions (App Store, direct download, Pro).
public enum KnownNotchApps {
    public static let displayNames = [
        "Alcove", "The Boring Notch", "Atoll", "DynamicLake", "Droppy",
        "Notchy", "MediaMate", "TopNotch", "NotchNook",
    ]

    /// Lowercased tokens without spaces or punctuation.
    static let tokens = [
        "alcove", "boringnotch", "atoll", "dynamiclake", "droppy",
        "notchy", "mediamate", "topnotch", "notchnook",
    ]

    public static func matches(name: String, bundleID: String?) -> Bool {
        let candidates = [name, bundleID ?? ""].map(normalize)
        return candidates.contains { candidate in
            tokens.contains { candidate.contains($0) }
        }
    }

    static func normalize(_ string: String) -> String {
        String(string.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}
