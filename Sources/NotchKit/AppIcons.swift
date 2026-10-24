import AppKit
import NotchCore

enum AppIcons {
    /// Resolves the current location of an assigned app: the stored path if it still exists,
    /// otherwise wherever Launch Services finds the bundle identifier now.
    static func url(for app: SlotApp) -> URL? {
        if FileManager.default.fileExists(atPath: app.path) {
            return URL(fileURLWithPath: app.path)
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID)
    }

    static func icon(for app: SlotApp, size: CGFloat) -> NSImage {
        let image: NSImage
        if let url = url(for: app) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = NSImage(systemSymbolName: "questionmark.app", accessibilityDescription: nil) ?? NSImage()
        }
        image.size = NSSize(width: size, height: size)
        return image
    }
}
