import AppKit
import IOKit.pwr_mgt
import NotchCore
import Observation

/// Watch mode: the island goes silent while you watch something. On by itself when a fullscreen
/// app is in front on the notch display or the front app keeps the display awake for video; on by
/// hand from the menu, the panel or ⌃⌥W, for a while or until turned off.
///
/// macOS Focus / Do Not Disturb isn't readable without the Focus permission, so it isn't used.
@MainActor
@Observable
final class WatchMode {
    private(set) var isOn = false
    private(set) var manualOn = false
    private(set) var manualUntil: Date?
    private(set) var fullscreen = false
    private(set) var videoPlaying = false
    /// Switched off by hand while on by itself; holds until the fullscreen app or video ends.
    private(set) var dismissed = false

    @ObservationIgnored var automatic: () -> Bool = { true }
    @ObservationIgnored var timer: () -> WatchTimer = { .twoHours }
    /// The display the island is on; fullscreen there is what counts.
    @ObservationIgnored var screen: () -> NSScreen? = { nil }
    @ObservationIgnored var onChange: ((Bool) -> Void)?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var poll: Task<Void, Never>?

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // The Space animation settles after the notification.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    MainActor.assumeIsolated { self?.check() }
                }
            })
        }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                self?.check()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func toggle() {
        if manualOn {
            manualOn = false
            manualUntil = nil
            dismissed = true  // off means off, even with a video still in front
        } else if isOn {
            dismissed = true  // on by itself (fullscreen or video): off until that ends
        } else {
            dismissed = false
            manualOn = true
            manualUntil = timer().seconds.map { Date().addingTimeInterval($0) }
        }
        Haptics.tick()
        check()
    }

    func check() {
        let automatic = automatic()
        if automatic {
            let front = NSWorkspace.shared.frontmostApplication
            fullscreen = Self.fullscreenApp(front, on: screen())
            videoPlaying = front.map { Self.keepsDisplayAwake(pid: $0.processIdentifier) } ?? false
        } else {
            fullscreen = false
            videoPlaying = false
        }
        if manualOn, let until = manualUntil, Date() >= until {
            manualOn = false
            manualUntil = nil
        }
        if !fullscreen && !videoPlaying { dismissed = false }
        let on = Quiet.watching(manualUntil: manualUntil, manualOn: manualOn, automatic: automatic,
                                fullscreen: fullscreen, videoPlaying: videoPlaying, dismissed: dismissed, now: Date())
        if on != isOn {
            isOn = on
            Log.app.info("Watch mode \(on ? "on" : "off", privacy: .public) (fullscreen \(self.fullscreen), video \(self.videoPlaying), manual \(self.manualOn), dismissed \(self.dismissed))")
            onChange?(on)
        }
    }

    /// The front app fills the notch display in a fullscreen Space. Fullscreen content may start
    /// below the notch band, so the window alone looks like a maximised one; what tells them apart
    /// is the Space: a normal one has the Dock's full-screen backstop window on screen, a
    /// fullscreen Space doesn't (measured on macOS 27).
    static func fullscreenApp(_ app: NSRunningApplication?, on island: NSScreen? = nil) -> Bool {
        guard let app, app.bundleIdentifier != Bundle.main.bundleIdentifier,
              let screen = island ?? NSScreen.screens.first(where: { $0.notch.hasNotch }) ?? NSScreen.main,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        // CG window bounds have their origin at the top left of the main display.
        let mainHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let frame = CGRect(x: screen.frame.minX, y: mainHeight - screen.frame.maxY,
                           width: screen.frame.width, height: screen.frame.height)
        var dockBackstop = false
        var filling = false
        for window in windows {
            guard let bounds = (window[kCGWindowBounds as String] as? [String: Double]).map({
                CGRect(x: $0["X"] ?? 0, y: $0["Y"] ?? 0, width: $0["Width"] ?? 0, height: $0["Height"] ?? 0)
            }), frame.intersects(bounds) else { continue }
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            let owner = window[kCGWindowOwnerPID as String] as? Int32 ?? 0
            if (window[kCGWindowOwnerName as String] as? String) == "Dock", layer == Int(CGWindowLevelForKey(.dockWindow)),
               Quiet.fills(window: bounds, screen: frame) {
                dockBackstop = true
            }
            // Fullscreen content may start below the notch: full width, down to the bottom, and
            // at least the screen minus the notch band tall.
            if layer == 0, owner == app.processIdentifier, abs(bounds.width - frame.width) <= 1,
               abs(bounds.maxY - frame.maxY) <= 1, bounds.height >= frame.height - 40 {
                filling = true
            }
        }
        return filling && !dockBackstop
    }

    /// The app holds a "keep the display on" power assertion (what video players and browsers
    /// playing video do). Reading assertions needs no permission.
    static func keepsDisplayAwake(pid: pid_t) -> Bool {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let byProcess = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return false }
        return (byProcess[NSNumber(value: pid)] ?? []).contains {
            ($0["AssertType"] as? String) == "PreventUserIdleDisplaySleep"
        }
    }
}
