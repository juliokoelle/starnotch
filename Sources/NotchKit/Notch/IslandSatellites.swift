import AppKit
import NotchCore
import Observation
import SwiftUI

/// "All displays" (Settings › Display): a copy of the island at rest on every display but the
/// island's own, with the same ears, lines and volume bar. Copies only show; the pointer, prompts
/// and sounds stay with the one island, which follows the pointer from display to display, and the
/// copy on the display it moves to gives way.
@MainActor
final class IslandSatellites {
    private struct Satellite {
        let panel: NotchPanel
        let model: NotchModel
    }

    private let source: NotchModel
    /// One per display, by display id; the one under the island is hidden, not dropped, so the
    /// island moving along costs no new window.
    private var satellites: [CGDirectDisplayID: Satellite] = [:]
    private var items: (NSScreen) -> [ClosedRange<CGFloat>] = { _ in [] }
    /// Following the island's state (one chain of observation at a time).
    private var mirroring = false
    /// Our own screenshots (`--capturable`) see the copies too.
    var capturable = false {
        didSet { for satellite in satellites.values { satellite.panel.sharingType = capturable ? .readOnly : .none } }
    }

    init(source: NotchModel) {
        self.source = source
    }

    /// Copies on `screens` but `island`'s (none: all gone), each drawn for its own display's notch
    /// and menu bar icons.
    func update(on screens: [NSScreen], island: NSScreen?, notch: @escaping (NSScreen) -> CGSize,
                items: @escaping (NSScreen) -> [ClosedRange<CGFloat>]) {
        self.items = items
        let ids = Dictionary(screens.compactMap { screen in screen.displayID.map { ($0, screen) } }) { first, _ in first }
        for (id, satellite) in satellites where ids[id] == nil {
            satellite.panel.orderOut(nil)
            satellites[id] = nil
        }
        for (id, screen) in ids {
            let satellite = satellites[id] ?? make()
            satellites[id] = satellite
            let size = notch(screen)
            satellite.model.notchSize = size
            satellite.model.hasNotch = screen.notch.hasNotch
            satellite.model.menuBarItems = items(screen)
            satellite.panel.setFrame(NotchController.panelFrame(on: screen, notch: size), display: false)
            if id == island?.displayID {
                satellite.panel.orderOut(nil)
            } else {
                satellite.panel.orderFrontRegardless()
            }
        }
        if !mirroring { mirror() }
    }

    /// The menu bar icons moved: each copy on a display with a notch fits them again.
    func refit() {
        for screen in NSScreen.screens {
            guard let id = screen.displayID, let satellite = satellites[id] else { continue }
            let items = items(screen)
            if satellite.model.menuBarItems != items { satellite.model.menuBarItems = items }
        }
    }

    /// Previews (`displays-all`): one copy as a display without a notch would show it, its panel
    /// at `frame` on this display.
    func preview(frame: CGRect, notch: CGSize) {
        let satellite = satellites[0] ?? make()
        satellites[0] = satellite
        satellite.model.notchSize = notch
        satellite.model.hasNotch = false
        satellite.panel.setFrame(frame, display: false)
        satellite.panel.orderFrontRegardless()
        if !mirroring { mirror() }
    }

    private func make() -> Satellite {
        let model = NotchModel(modules: source.modules)
        model.show(source.mirror)
        model.restEars = { [weak source] in source?.restEars() }
        let panel = NotchPanel()
        panel.sharingType = capturable ? .readOnly : .none
        let hosting = NSHostingView(rootView: NotchRootView(model: model, onTapIsland: {}, onKey: { _ in .ignored }))
        hosting.safeAreaRegions = []
        panel.contentView = hosting
        return Satellite(panel: panel, model: model)
    }

    /// Follows the island's state while there are copies: reads it under observation, hands it to
    /// every copy, and does so again on the next change.
    private func mirror() {
        mirroring = !satellites.isEmpty
        guard mirroring else { return }
        let state = withObservationTracking { source.mirror } onChange: { [weak self] in
            Task { @MainActor in self?.mirror() }
        }
        for satellite in satellites.values { satellite.model.show(state) }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
