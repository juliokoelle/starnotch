import AppKit
import NotchCore

/// Entry point for a build of the app. The public build passes no connectors; a private build
/// passes its own connector types and, optionally, its defaults in config.toml syntax (the
/// user's `config.toml` overrides them key by key).
@MainActor
public enum NotchApp {
    private static var delegate: AppDelegate?

    public static func main(connectors: [any NotchConnector.Type], buildConfig: String = "") -> Never {
        Runtime.start(connectorTypes: connectors, buildConfig: buildConfig)
        Localization.apply(Runtime.language)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)  // menu bar agent, no Dock icon (LSUIElement)
        EditMenu.install()
        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        app.run()
        exit(0)
    }
}
