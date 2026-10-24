import Foundation

/// Interface language. Strings live in `Resources/Localization/<lang>.lproj/Localizable.strings`
/// (copied into the app bundle); SwiftUI `Text("…")` literals look them up by their English text.
/// `[general] language` in config.toml can pin a language instead of following the system.
enum Localization {
    static let supported = ["en", "de"]

    /// Must run before the first window: pins `AppleLanguages` for this app, or clears the pin.
    static func apply(_ language: String) {
        let defaults = UserDefaults.standard
        let pinned = defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] != nil
        if supported.contains(language) {
            // Already what the system picks: leave the system's settings alone.
            let systemPick = Bundle.preferredLocalizations(from: supported, forPreferences: Locale.preferredLanguages).first
            if systemPick == language && !pinned { return }
            defaults.set([language], forKey: "AppleLanguages")
        } else if pinned {
            defaults.removeObject(forKey: "AppleLanguages")
        }
    }

    /// For strings outside SwiftUI `Text` (menus, sneaks).
    static func string(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }
}
