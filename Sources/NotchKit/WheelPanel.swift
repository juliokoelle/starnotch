import AppKit

/// Borderless, transparent, non-activating panel that covers one screen above everything,
/// including the menu bar and other notch apps, on every Space.
final class WheelPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        sharingType = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isFloatingPanel = true
        // After `isFloatingPanel`, which resets the level to `.floating` (3). Notch apps draw at
        // 25 to 27 (Notchy, Boring Notch, Atoll) and QuakeNotch even at `.screenSaver` (1000),
        // so one above that keeps the wheel on top of their expanded panels.
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
    }

    // Needed in click mode so Escape reaches the app.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
