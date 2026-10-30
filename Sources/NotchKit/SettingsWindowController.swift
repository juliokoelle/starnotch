import NotchCore
import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let state: AppState
    private let cast: AvatarCast
    private let catalog = AppCatalog()
    private var window: NSWindow?
    private let setup: SetupCenter?
    private let jamie: JamieConnect?
    private let openSetup: (Onboarding.Step) -> Void

    init(state: AppState, cast: AvatarCast, setup: SetupCenter? = nil, jamie: JamieConnect? = nil,
         openSetup: @escaping (Onboarding.Step) -> Void = { _ in }) {
        self.state = state
        self.cast = cast
        self.setup = setup
        self.jamie = jamie
        self.openSetup = openSetup
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(state: state, catalog: catalog, cast: cast, setup: setup, jamie: jamie,
                                                                  openSetup: openSetup).dashboardControls())
            hosting.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = Brand.displayName
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()  // activation is cooperative since macOS 14
    }

    /// Recordings: the window just under the notch, short enough for a region capture.
    func showForTour() {
        show()
        guard let window, let screen = NSScreen.screens.first(where: { $0.notch.hasNotch }) ?? NSScreen.main else { return }
        let topLeft = NSPoint(x: screen.notch.rect.midX - 280, y: screen.frame.maxY - 300)
        window.setFrameTopLeftPoint(topLeft)
        // The hosting controller resizes the window to its content once laid out; pin it again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { window.setFrameTopLeftPoint(topLeft) }
    }
}
