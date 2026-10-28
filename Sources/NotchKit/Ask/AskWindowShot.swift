import AppKit
import ImageIO
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

/// Tara dropped on a window: which window lies under the pointer, and a picture of it for the
/// question (ScreenCaptureKit; macOS asks for Screen Recording the first time).
enum AskWindowShot {
    struct Target: Equatable, Sendable {
        let windowID: CGWindowID
        /// The app the window belongs to, for the chip in the field.
        let app: String
    }

    /// The topmost normal window of another app under a point in AppKit screen coordinates.
    static func window(at point: CGPoint) -> Target? {
        // Window bounds count from the top left of the main display; AppKit's from its bottom left.
        guard let main = NSScreen.screens.first else { return nil }
        let flipped = CGPoint(x: point.x, y: main.frame.maxY - point.y)
        let own = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? Int32) != own,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.contains(flipped), rect.width > 80, rect.height > 60 else { continue }
            return Target(windowID: id, app: info[kCGWindowOwnerName as String] as? String ?? "")
        }
        return nil
    }

    enum Failure: Error { case noPermission, gone, unwritable }

    /// Not the agent's `starnotch-image-*`: its sweep would delete a picture still attached.
    static let prefix = "starnotch-window-"

    /// Deletes pictures a crash or force quit left behind (also those of builds that used the agent's prefix).
    static func removeLeftovers(in folder: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix(prefix) || name.hasPrefix("starnotch-image-window-") {
            try? FileManager.default.removeItem(at: folder.appending(path: name))
        }
    }

    /// A JPEG of the window (at most 1600 px on its long side) in `folder`; the caller deletes it.
    nonisolated static func capture(_ target: Target, into folder: URL) async throws -> URL {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            throw Failure.noPermission
        }
        guard let window = content.windows.first(where: { $0.windowID == target.windowID }) else { throw Failure.gone }
        let config = SCStreamConfiguration()
        let longSide = max(window.frame.width, window.frame.height)
        let scale = min(2, 1600 / max(longSide, 1))
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                                               configuration: config)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "\(prefix)\(UUID().uuidString).jpg")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw Failure.unwritable
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.unwritable }
        return url
    }
}
