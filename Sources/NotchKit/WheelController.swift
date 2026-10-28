import AppKit
import NotchCore
import SwiftUI

/// Gesture state machine: press and hold on the notch, drag, release. Also the shortcut
/// (click) mode. Shows and hides the wheel panel and hands selections to `AppSwitcher`.
@MainActor
final class WheelController {
    private enum Phase: Equatable {
        case idle
        case pressing
        case holding
        case clicking
        case dismissing
    }

    private let state: AppState
    private let switcher: AppSwitcher
    private let model = WheelModel()
    private let panel = WheelPanel()
    private var phase = Phase.idle
    private var monitors: [Any] = []
    private var pressTask: Task<Void, Never>?
    private var pressStart: CGPoint = .zero
    private var dismissTask: Task<Void, Never>?
    /// Wheel center in global AppKit coordinates.
    private var wheelCenter = CGPoint.zero

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// A press on the notch released before the hold duration: a plain click.
    var onTapNotch: (() -> Void)?
    /// A press on the notch pulled down: the main character comes out.
    var onPullDown: (() -> Void)?
    /// A press on the notch or the closed island began (`true`) or ended: Tara squashes meanwhile.
    var onPress: ((Bool) -> Void)?
    /// The island around the notch (peek, dictation): a press there may pull too, without the wheel.
    var canPull: ((CGPoint) -> Bool)?
    private var pullArmed = false
    var onWillOpen: (() -> Void)?
    var onDidClose: (() -> Void)?
    /// A module slot was chosen.
    var onSelectModule: ((ModuleKind) -> Void)?
    /// Slot of the module the notch shows, marked as active on the wheel.
    var currentModuleSlot: (() -> SlotPosition?)?

    init(state: AppState, switcher: AppSwitcher) {
        self.state = state
        self.switcher = switcher
        let hosting = NSHostingView(rootView: WheelCanvas(model: model))
        hosting.safeAreaRegions = []
        panel.contentView = hosting
    }

    // MARK: Event monitoring

    func startMonitoring() {
        // Passive global monitors: we observe presses on the notch without stealing them.
        // Mouse events arrive without special permission; the key monitor (Escape while
        // holding) only receives events once Accessibility access is granted.
        let globalMask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: globalMask, handler: { [weak self] event in
            MainActor.assumeIsolated { _ = self?.handle(event, isLocal: false) }
        }) {
            monitors.append(global)
        }
        let localMask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved, .keyDown]
        if let local = NSEvent.addLocalMonitorForEvents(matching: localMask, handler: { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handle(event, isLocal: true) ?? false }
            return consumed ? nil : event
        }) {
            monitors.append(local)
        }
    }

    /// Returns `true` if the event was consumed (only meaningful for local events).
    private func handle(_ event: NSEvent, isLocal: Bool) -> Bool {
        if event.type == .leftMouseUp { onPress?(false) }
        switch (event.type, phase) {
        case (.leftMouseDown, .idle):
            beginPress()
            // Outside the notch's hot zone but on the open-ish island: only a pull, never the wheel.
            if phase == .idle, canPull?(NSEvent.mouseLocation) == true {
                pullArmed = true
                pressStart = NSEvent.mouseLocation
            }
            if phase == .pressing || pullArmed { onPress?(true) }
            return false
        case (.leftMouseDragged, .idle) where pullArmed:
            if pressStart.y - NSEvent.mouseLocation.y > 24 {
                pullArmed = false
                onPress?(false)
                onPullDown?()
            }
            return false
        case (.leftMouseUp, .idle) where pullArmed:
            pullArmed = false
            return false
        case (.leftMouseUp, .pressing):
            cancelPress()
            onTapNotch?()
            return false
        case (.leftMouseDragged, .pressing):
            // Pulled down out of the notch, in any state: the main character comes out. Moved
            // any other way before the wheel opens: a drag, not a hold or a tap.
            let mouse = NSEvent.mouseLocation
            if pressStart.y - mouse.y > 24 {
                cancelPress()
                onPress?(false)
                onPullDown?()
            } else if abs(mouse.x - pressStart.x) > 12 || mouse.y - pressStart.y > 8 {
                cancelPress()
            }
            return false
        case (.leftMouseDragged, .holding), (.mouseMoved, .clicking):
            updateHighlight()
            return phase == .clicking
        case (.leftMouseUp, .holding):
            commit()
            return false
        case (.leftMouseDown, .clicking):
            if isLocal {
                updateHighlight()
                commit()
                return true
            }
            cancel()  // A click on another screen or app ends click mode.
            return false
        case (.keyDown, .holding), (.keyDown, .clicking):
            if event.keyCode == 53 {  // Escape
                cancel()
                return true
            }
            if event.keyCode == 36 || event.keyCode == 76, phase == .clicking {  // Return, Enter
                commit()
                return true
            }
            return phase == .clicking
        default:
            return false
        }
    }

    // MARK: Hold gesture

    private func beginPress() {
        let location = NSEvent.mouseLocation
        guard let screen = NSScreen.withHotZone(containing: location) else { return }
        phase = .pressing
        pressStart = location
        let delay = state.settings.holdDuration
        pressTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, self.phase == .pressing else { return }
            if NSEvent.pressedMouseButtons & 1 == 1 {
                self.open(on: screen, mode: .hold)
            } else {
                self.phase = .idle
            }
        }
    }

    private func cancelPress() {
        pressTask?.cancel()
        pressTask = nil
        phase = .idle
    }

    // MARK: Showing and hiding

    /// A slot as the wheel offers it: a tab only while the notch shows it (switched on, and what
    /// it needs is on this Mac); otherwise the slot stays empty.
    private func offered(at position: SlotPosition) -> SlotItem? {
        let item = state.settings.wheelItem(at: position)
        if case .module(let kind) = item, !ModuleAvailability.isShown(kind, settings: state.settings) { return nil }
        return item
    }

    /// Opens the wheel in click mode (keyboard shortcut, menu, `--open-wheel`).
    func openFromShortcut() {
        switch phase {
        case .clicking, .holding:
            cancel()
        case .idle, .dismissing, .pressing:
            guard let screen = NSScreen.preferredForWheel else { return }
            open(on: screen, mode: .click)
        }
    }

    private func open(on screen: NSScreen, mode: WheelModel.Mode) {
        dismissTask?.cancel()
        onWillOpen?()
        let notch = screen.notch.rect
        wheelCenter = CGPoint(
            x: notch.midX,
            y: notch.minY - WheelMetrics.gapBelowNotch - WheelMetrics.radius
        )

        model.mode = mode
        model.slots = Dictionary(uniqueKeysWithValues: SlotPosition.allCases.compactMap { position in
            switch offered(at: position) {
            case .module(let kind):
                (position, WheelModel.Slot(name: kind.title, symbol: ModuleSymbols.symbol(kind)))
            case .app(let app):
                (position, WheelModel.Slot(name: app.name, icon: AppIcons.icon(for: app, size: 128)))
            case nil:
                nil
            }
        })
        state.refreshRunningApps()
        model.activeSlot = currentModuleSlot?() ?? state.activeSlot
        model.highlighted = nil
        model.center = CGPoint(x: wheelCenter.x - screen.frame.minX, y: screen.frame.maxY - wheelCenter.y)
        model.isPresented = false

        panel.setFrame(screen.frame, display: false)
        panel.ignoresMouseEvents = mode == .hold
        phase = mode == .hold ? .holding : .clicking

        if mode == .click {
            // A non-activating panel becomes key without activating the app (like Spotlight),
            // so Escape and Return reach us while the frontmost app keeps its focus.
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
            // Put the pointer in the middle of the wheel so every slot is one flick away,
            // like a game's weapon wheel. The notch sits at the screen edge, so without this
            // the top slot could never be reached by dragging upward.
            warpPointer(to: wheelCenter)
        }

        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.34, dampingFraction: 0.76)) {
            model.isPresented = true
        }
        Log.wheel.info("Wheel opened (\(mode == .hold ? "hold" : "click", privacy: .public))")
    }

    private func updateHighlight() {
        let location = NSEvent.mouseLocation
        let slot = WheelMath.selectableSlot(
            dx: location.x - wheelCenter.x,
            dy: location.y - wheelCenter.y,
            deadZone: WheelMetrics.hubRadius,
            maxDistance: phase == .clicking ? WheelMetrics.radius + 12 : nil,
            assigned: Set(SlotPosition.allCases.filter { offered(at: $0) != nil })
        )
        guard slot != model.highlighted else { return }
        model.setHighlight(slot)
        if slot != nil {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    func allowCapture() { panel.sharingType = .readOnly }

    private func commit() {
        guard let slot = model.highlighted, let item = offered(at: slot) else {
            cancel()
            return
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        guard case .app(let target) = item else {
            if case .module(let kind) = item {
                Log.wheel.info("Selected \(slot.label, privacy: .public): module \(kind.rawValue, privacy: .public)")
                model.activeSlot = slot
                dismiss()
                onSelectModule?(kind)
            }
            return
        }
        Log.wheel.info("Selected \(slot.label, privacy: .public): \(target.bundleID, privacy: .public)")

        state.refreshRunningApps()
        if let plan = SwitchPlan.make(
            slots: state.settings.appBundleIDs,
            selected: slot,
            running: state.runningBundleIDs
        ) {
            state.settings.activeSlot = slot
            model.activeSlot = slot
            switcher.perform(
                plan,
                target: target,
                forceQuit: state.settings.forceQuitEnabled,
                timeout: state.settings.forceQuitTimeout
            )
        }
        dismiss()
    }

    private func cancel() {
        Log.wheel.info("Wheel cancelled")
        dismiss()
    }

    private func dismiss() {
        guard phase == .holding || phase == .clicking else { return }
        phase = .dismissing
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.24, dampingFraction: 0.9)) {
            model.isPresented = false
        }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard let self, !Task.isCancelled else { return }
            self.panel.orderOut(nil)
            self.model.highlighted = nil
            self.phase = .idle
            self.onDidClose?()
        }
    }

    private func warpPointer(to point: CGPoint) {
        // CoreGraphics uses a top-left origin on the primary screen.
        guard let primary = NSScreen.screens.first else { return }
        CGWarpMouseCursorPosition(CGPoint(x: point.x, y: primary.frame.maxY - point.y))
        // Re-associating removes the short input freeze that follows a warp.
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}
