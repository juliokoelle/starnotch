import NotchCore
import AppKit

/// The menu bar icon and its menu.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let state: AppState
    private let onToggleNotch: () -> Void
    private let onOpenWheel: () -> Void
    private let onOpenSettings: () -> Void
    private let activeItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let watchItem = NSMenuItem(title: "Watch mode", action: nil, keyEquivalent: "w")
    /// Watch mode: is it on, and the toggle.
    var watching: () -> Bool = { false }
    var onToggleWatch: () -> Void = {}
    private let awakeItem = NSMenuItem(title: "Keep awake", action: nil, keyEquivalent: "")
    var keepingAwake: () -> Bool = { false }
    var onToggleKeepAwake: () -> Void = {}
    var onOpenSetup: () -> Void = {}
    /// Release builds with Sparkle: "Check for Updates…".
    var updater: Updater? {
        didSet {
            guard let updater, updater.isAvailable, let menu = statusItem.menu else { return }
            let item = NSMenuItem(title: "Check for Updates…", action: #selector(checkUpdates), keyEquivalent: "")
            item.target = self
            menu.insertItem(item, at: max(0, menu.items.count - 2))
        }
    }

    init(state: AppState, onToggleNotch: @escaping () -> Void, onOpenWheel: @escaping () -> Void, onOpenSettings: @escaping () -> Void) {
        self.state = state
        self.onToggleNotch = onToggleNotch
        self.onOpenWheel = onOpenWheel
        self.onOpenSettings = onOpenSettings
        super.init()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "circle.grid.cross", accessibilityDescription: Brand.displayName)
            image?.isTemplate = true
            button.image = image
        }

        let menu = NSMenu()
        menu.delegate = self
        activeItem.isEnabled = false
        menu.addItem(activeItem)
        menu.addItem(.separator())

        let notch = NSMenuItem(title: "Open Notch", action: #selector(toggleNotch), keyEquivalent: " ")
        notch.keyEquivalentModifierMask = [.control, .option]
        notch.target = self
        menu.addItem(notch)

        let wheel = NSMenuItem(title: "Open Wheel", action: #selector(openWheel), keyEquivalent: "")
        wheel.target = self
        menu.addItem(wheel)

        watchItem.action = #selector(toggleWatch)
        watchItem.keyEquivalentModifierMask = [.control, .option]
        watchItem.image = NSImage(systemSymbolName: "moon", accessibilityDescription: nil)
        watchItem.target = self
        menu.addItem(watchItem)

        awakeItem.action = #selector(toggleAwake)
        awakeItem.image = NSImage(systemSymbolName: "cup.and.saucer", accessibilityDescription: nil)
        awakeItem.target = self
        menu.addItem(awakeItem)

        let setup = NSMenuItem(title: "Set up…", action: #selector(openSetup), keyEquivalent: "")
        setup.target = self
        menu.addItem(setup)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit \(Brand.displayName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func toggleWatch() { onToggleWatch() }
    @objc private func toggleAwake() { onToggleKeepAwake() }
    @objc private func openSetup() { onOpenSetup() }
    @objc private func checkUpdates() { updater?.checkForUpdates() }

    func menuNeedsUpdate(_ menu: NSMenu) {
        watchItem.state = watching() ? .on : .off
        awakeItem.state = keepingAwake() ? .on : .off
        state.refreshRunningApps()
        if let slot = state.activeSlot, let app = state.settings[slot] {
            activeItem.title = "Active: \(app.name)"
        } else {
            activeItem.title = "Hold the notch to switch modules"
        }
    }

    @objc private func toggleNotch() {
        Task { self.onToggleNotch() }
    }

    @objc private func openWheel() {
        // Let the menu close before the wheel takes over the screen.
        Task { self.onOpenWheel() }
    }

    @objc private func openSettings() {
        onOpenSettings()
    }
}
