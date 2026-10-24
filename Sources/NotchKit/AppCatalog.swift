import AppKit
import NotchCore
import Observation

struct CatalogApp: Identifiable, Hashable {
    var name: String
    var bundleID: String
    var url: URL
    var isNotchApp: Bool

    var id: String { bundleID }

    var slotApp: SlotApp { SlotApp(bundleID: bundleID, name: name, path: url.path) }
}

/// Installed apps the user can put into a slot. Known notch apps are listed first.
@MainActor
@Observable
final class AppCatalog {
    private(set) var notchApps: [CatalogApp] = []
    private(set) var otherApps: [CatalogApp] = []

    private static let folders: [URL] = [
        URL(fileURLWithPath: "/Applications"),
        URL(fileURLWithPath: "/Applications/Utilities"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        URL(fileURLWithPath: "/System/Applications"),
        URL(fileURLWithPath: "/System/Applications/Utilities"),
    ]

    func refresh() {
        var seen = Set<String>()
        var apps: [CatalogApp] = []
        let ownID = Bundle.main.bundleIdentifier
        for folder in Self.folders {
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )) ?? []
            for url in urls where url.pathExtension == "app" {
                guard let bundleID = Bundle(url: url)?.bundleIdentifier,
                      bundleID != ownID, seen.insert(bundleID).inserted else { continue }
                let name = FileManager.default.displayName(atPath: url.path)
                    .replacingOccurrences(of: ".app", with: "")
                apps.append(CatalogApp(
                    name: name,
                    bundleID: bundleID,
                    url: url,
                    isNotchApp: KnownNotchApps.matches(name: name, bundleID: bundleID)
                ))
            }
        }
        apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        notchApps = apps.filter(\.isNotchApp)
        otherApps = apps.filter { !$0.isNotchApp }
    }

    /// Lets the user pick any app bundle with an open panel.
    func chooseApp() -> CatalogApp? {
        let panel = NSOpenPanel()
        panel.title = "Choose an App"
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return nil }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        return CatalogApp(
            name: name, bundleID: bundleID, url: url,
            isNotchApp: KnownNotchApps.matches(name: name, bundleID: bundleID)
        )
    }
}
