import AppKit
import NotchCore
import Observation
import ServiceManagement

/// Shared, observable app state: persisted settings plus live system status.
@MainActor
@Observable
final class AppState {
    static let shortcutDisplay = "⌃⌥Space"

    var settings: SwitcherSettings {
        didSet {
            if settings != oldValue { store.save(settings) }
            if settings.localAPIEnabled != oldValue.localAPIEnabled { onLocalAPIToggle?(settings.localAPIEnabled) }
            if settings.disabledModules != oldValue.disabledModules || settings.remindersInToday != oldValue.remindersInToday {
                onModulesChanged?()
            }
            if settings.islandDisplay != oldValue.islandDisplay { onDisplayChanged?() }
            if settings.earsMode != oldValue.earsMode { onEarsModeChanged?(settings.earsMode) }
            if settings.disabledProviders != oldValue.disabledProviders { onProvidersChanged?(Set(settings.disabledProviders)) }
        }
    }
    @ObservationIgnored var onProvidersChanged: ((Set<String>) -> Void)?
    @ObservationIgnored var onLocalAPIToggle: ((Bool) -> Void)?
    @ObservationIgnored var onModulesChanged: (() -> Void)?
    @ObservationIgnored var onDisplayChanged: (() -> Void)?
    @ObservationIgnored var onEarsModeChanged: ((EarsMode) -> Void)?
    private(set) var isAccessibilityTrusted = AXIsProcessTrusted()
    private(set) var loginItemStatus = SMAppService.mainApp.status
    private(set) var loginItemError: String?
    /// Bundle identifiers of running apps, kept current through NSWorkspace notifications.
    private(set) var runningBundleIDs: Set<String> = []

    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    init(store: SettingsStore = SettingsStore()) {
        self.store = store
        self.settings = store.load()
        // Drop app slots whose app is gone (e.g. notch apps uninstalled after trying them).
        for slot in SlotPosition.allCases {
            if let app = settings[slot], !FileManager.default.fileExists(atPath: app.path),
               NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) == nil {
                settings[slot] = nil
            }
        }
        refreshRunningApps()

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshRunningApps() }
            })
        }

        // There is no notification for Accessibility changes, so poll cheaply.
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.refreshAccessibility()
            }
        }
    }

    // MARK: Slots

    /// The slot whose app is running, preferring the slot that was selected last.
    var activeSlot: SlotPosition? {
        if let remembered = settings.activeSlot, let app = settings[remembered],
           runningBundleIDs.contains(app.bundleID) {
            return remembered
        }
        return SlotPosition.allCases.first { slot in
            settings[slot].map { runningBundleIDs.contains($0.bundleID) } ?? false
        }
    }

    func refreshRunningApps() {
        let ids = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        if ids != runningBundleIDs { runningBundleIDs = ids }
    }

    // MARK: Accessibility

    func refreshAccessibility() {
        let trusted = AXIsProcessTrusted()
        if trusted != isAccessibilityTrusted { isAccessibilityTrusted = trusted }
    }

    /// Shows the system prompt that adds the app to the Accessibility list.
    func requestAccessibility() {
        // "AXTrustedCheckOptionPrompt" is the value of kAXTrustedCheckOptionPrompt.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    // MARK: Launch at login

    var launchAtLogin: Bool {
        loginItemStatus == .enabled || loginItemStatus == .requiresApproval
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
            Log.app.error("Launch at login failed: \(error.localizedDescription, privacy: .public)")
        }
        loginItemStatus = SMAppService.mainApp.status
    }

    func refreshLoginItemStatus() {
        loginItemStatus = SMAppService.mainApp.status
    }
}
