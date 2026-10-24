import AppKit
#if canImport(Sparkle)
import Sparkle
#endif

/// Updates through Sparkle 2 in release builds (STARNOTCH_SPARKLE=1 with a feed URL and public
/// key in Info.plist); other builds have no updater and the menu item doesn't show.
@MainActor
final class Updater {
    #if canImport(Sparkle)
    private let controller: SPUStandardUpdaterController?

    init() {
        let configured = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
            && Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil
        controller = configured ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil) : nil
    }

    var isAvailable: Bool { controller != nil }
    func checkForUpdates() { controller?.checkForUpdates(nil) }
    #else
    init() {}
    var isAvailable: Bool { false }
    func checkForUpdates() {}
    #endif
}
