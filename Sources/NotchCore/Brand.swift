import Foundation

/// The app's name in one place: changing `name` here renames the app (the build script reads
/// this line too). A private build can keep its own bundle
/// name, support folder and link scheme through its Info.plist (see `scripts/build-app.sh`).
public enum Brand {
    /// The product name.
    public static let name = "Starnotch"

    /// The product name in the interface. A private build may keep another bundle name; the
    /// interface still says the product's name.
    public static var displayName: String { name }

    /// The bundle's name as macOS lists it (System Settings, Login Items).
    public static var bundleName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? name
    }

    /// Folder under `~/Library/Application Support` for the config, the API token and the queue.
    public static var supportFolderName: String {
        (Bundle.main.object(forInfoDictionaryKey: "NotchSupportFolder") as? String) ?? name
    }

    /// `<scheme>://status?title=…` posts a status line.
    public static var urlScheme: String {
        (Bundle.main.object(forInfoDictionaryKey: "NotchURLScheme") as? String) ?? name.lowercased()
    }

    /// Logging subsystem and queue labels.
    public static var identifier: String { Bundle.main.bundleIdentifier ?? "app.\(name.lowercased())" }

    public static var supportFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support")
            .appending(path: supportFolderName)
    }
}
