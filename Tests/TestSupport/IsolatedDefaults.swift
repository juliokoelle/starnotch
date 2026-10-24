import Foundation
import NotchCore

/// A `SettingsStore` under a unique key in a shared test suite; the key is removed afterwards.
/// (One suite instead of one per test, so test runs don't leave plist files behind.)
public final class IsolatedSettings {
    public let store: SettingsStore
    private let defaults = UserDefaults(suiteName: "app.starnotch.tests")!
    private let key = "settings.\(UUID().uuidString)"

    public init() {
        store = SettingsStore(defaults: defaults, key: key)
    }

    deinit {
        defaults.removeObject(forKey: key)
    }

    /// Writes raw bytes under the store's key, e.g. older or corrupt JSON.
    public func writeRaw(_ string: String) {
        defaults.set(Data(string.utf8), forKey: key)
    }
}
