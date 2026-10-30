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
    private let inboxItem = NSMenuItem(title: "Open Inbox", action: nil, keyEquivalent: "i")
    private let meetingNotesItem = NSMenuItem(title: "Open Meeting Notes", action: nil, keyEquivalent: "")
    /// What the meeting agent showed, in full (written by agent/feed.py).
    static var meetingNotesFile: URL { Brand.supportFolder.appending(path: "Meeting-Agent.md") }
    private let awakeItem = NSMenuItem(title: "Keep awake", action: nil, keyEquivalent: "")
    var keepingAwake: () -> Bool = { false }
    var onToggleKeepAwake: () -> Void = {}
    var onOpenSetup: () -> Void = {}
    var onOpenDashboard: () -> Void = {}
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

        inboxItem.action = #selector(openInbox)
        inboxItem.keyEquivalentModifierMask = [.control, .option]
        inboxItem.target = self
        menu.addItem(inboxItem)

        meetingNotesItem.action = #selector(openMeetingNotes)
        meetingNotesItem.target = self
        menu.addItem(meetingNotesItem)

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

        let dashboard = NSMenuItem(title: Localization.string("Dashboard…"), action: #selector(openDashboard), keyEquivalent: "d")
        dashboard.target = self
        menu.addItem(dashboard)

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
    @objc private func openDashboard() { onOpenDashboard() }
    @objc private func checkUpdates() { updater?.checkForUpdates() }
    @objc private func openInbox() { if let file = CaptureInbox.markdownFile { CaptureInbox.openMarkdown(file) } }
    @objc private func openMeetingNotes() { NSWorkspace.shared.open(Self.meetingNotesFile) }

    func menuNeedsUpdate(_ menu: NSMenu) {
        watchItem.state = watching() ? .on : .off
        awakeItem.state = keepingAwake() ? .on : .off
        // Only the tools switched on in Settings › Tools.
        awakeItem.isHidden = !ToolSwitches.isOn(.keepAwake, in: state.settings)
        inboxItem.isHidden = CaptureInbox.markdownFile == nil || !ToolSwitches.isOn(.quickCapture, in: state.settings)
        meetingNotesItem.isHidden = !FileManager.default.fileExists(atPath: Self.meetingNotesFile.path)
            || state.settings.disabledModules.contains(.meeting)
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
