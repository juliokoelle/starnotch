import AppKit
import NotchCore
import SwiftUI

/// Transparent, non-activating panel at the top of the notch screen. It never resizes; the
/// island animates inside it, and the panel only takes mouse events while the pointer is over
/// the island, so everything around it stays clickable.
final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Invisible in screen sharing and recordings of other apps (Zoom, Meet).
        sharingType = .none
        isFloatingPanel = true
        // Above the menu bar, below the wheel (screen saver + 1).
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Input and state for the island: hover peeks, a click expands, leaving or clicking elsewhere
/// collapses, ⌃⌥Space opens it with keyboard focus. The hold gesture on the notch belongs to
/// `WheelController`, which reports plain taps back here.
@MainActor
final class NotchController {
    let model: NotchModel
    private let panel = NotchPanel()
    private var screen: NSScreen?
    /// The display the island is on (Watch mode looks for fullscreen there).
    var islandScreen: NSScreen? { screen }
    private var monitors: [Any] = []
    private var hoverTask: Task<Void, Never>?
    private var leaveTask: Task<Void, Never>?
    /// Opened from the wheel or the keyboard: stays open until the pointer has been inside and
    /// left again, a click lands elsewhere, or Escape.
    private var pinned = false
    private var wheelOpen = false
    private var suppressUntil = Date.distantPast
    /// Hover physics (after boring.notch's behavior, not its code): a tick on entering, the peek
    /// only after a short dwell, a grace period on leaving, and a stay zone larger than the shape
    /// so a slightly wobbly pointer doesn't close it.
    static let hoverDwell: Duration = .milliseconds(200)
    /// After the pointer leaves: the peek goes quickly, the open panel forgives a slip or a quick
    /// trip to another window.
    static let leaveGrace: TimeInterval = 0.1
    static let expandedLeaveGrace: TimeInterval = 0.75
    /// No collapse this soon after a click inside the panel.
    static let clickHold: TimeInterval = 1.5
    private var lastPanelClick = Date.distantPast
    /// Keep-open setting and modules showing a detail card.
    var keepsOpen: () -> Bool = { false }
    /// Seconds the pointer rests on the notch before it opens (nil: only a click opens it).
    var hoverOpenDelay: () -> Double? = { nil }
    /// Closed, the panel keeps its tab for the next open (a setting); else it goes back to the first.
    var reopensLastTab: () -> Bool = { true }
    static let stayMargin: CGFloat = 30
    private var pointerInside = false
    /// Demos and screenshots (`--expand`, `--tour`): ignore the real pointer so the states stay put.
    var isLocked = false
    /// Quick capture's destination (queue file, hub).
    let inbox = CaptureInbox()
    /// The menu bar icons, so the open island ends between them.
    private let menuBar = MenuBarExtras()
    /// Previews: icons to pretend are in the menu bar (extents from the notch centre) instead of
    /// the real ones.
    var simulatedMenuBarItems: [ClosedRange<CGFloat>]? {
        didSet { fitToMenuBar() }
    }
    /// The command palette's providers and memory.
    let paletteSources = PaletteSources()

    /// For our own screenshots and recordings (`--capturable`); otherwise the island stays out
    /// of screen sharing and captures.
    func allowCapture() { panel.sharingType = .readOnly }

    /// Which display the island lives on (a setting).
    private let display: () -> IslandDisplay

    init(model: NotchModel, display: @escaping () -> IslandDisplay = { .automatic }) {
        self.model = model
        self.display = display
        // When the last lock goes, re-check the pointer: if it left meanwhile, collapse as usual.
        IslandLock.shared.onUnlock = { [weak self] in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                self?.pointerMoved()
            }
        }
        let root = NotchRootView(
            model: model,
            onTapIsland: { [weak self] in
                if let url = self?.model.sneak?.url, url.scheme == Brand.urlScheme {
                    // Our own links stay in this app, even when another copy is registered for the scheme.
                    NSApp.delegate?.application?(NSApp, open: [url])
                } else if let url = self?.model.sneak?.url {
                    NSWorkspace.shared.open(url)
                } else {
                    self?.expandFromClick()
                }
            },
            onKey: { [weak self] in self?.handleKey($0) ?? .ignored },
            onCaptureSend: { [weak self] in self?.sendCapture() },
            onCaptureMic: { [weak self] in self?.toggleCaptureMic() },
            onCaptureEvent: { [weak self] in self?.createCaptureEvent() },
            onCaptureShowNotes: { [weak self] in self?.showCapturedNotes() },
            onCaptureOpenInbox: { [weak self] in self?.openCaptureInbox() },
            onPaletteActivate: { [weak self] index, secondary in self?.activatePalette(index, secondary: secondary) },
            onInboxKey: { [weak self] primary, id in self?.inboxKey(primary: primary, id: id) },
            onInboxEmpty: { [weak self] in self?.inboxEmptied() }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.safeAreaRegions = []
        panel.contentView = hosting
        menuBar.onChange = { [weak self] in self?.fitToMenuBar() }
        place()
        watchEars()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
    }

    // MARK: Placement

    /// Moves the island to the display the setting asks for (after a change in Settings).
    func placeOnScreen() {
        guard model.interaction == .rest else { return }
        place()
    }

    /// The display for the island: the notch screen (else the main one), the main screen (the one
    /// with the menu bar), or the screen under the pointer. Displays without a notch get a pill in
    /// menu bar height at the top center.
    private func targetScreen() -> NSScreen? {
        switch display() {
        case .automatic:
            return NSScreen.screens.first(where: { $0.notch.hasNotch }) ?? NSScreen.main
        case .main:
            return NSScreen.screens.first ?? NSScreen.main
        case .pointer:
            let mouse = NSEvent.mouseLocation
            return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        }
    }

    private func place() {
        guard let screen = targetScreen() else { return }
        self.screen = screen
        let notch = screen.notch
        model.notchSize = notch.rect.size
        model.hasNotch = notch.hasNotch
        let max = NotchLayout.maxSize(notch: notch.rect.size)
        let shadowPad: CGFloat = 40
        let size = CGSize(width: max.width + 2 * shadowPad, height: max.height + shadowPad)
        panel.setFrame(
            CGRect(x: notch.rect.midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height),
            display: true
        )
        fitToMenuBar()
        menuBar.refresh(full: true)
    }

    /// Hands the layout the menu bar icons beside this screen's notch, so the open island ends
    /// between two of them. A display without a notch keeps the island's own widths.
    private func fitToMenuBar() {
        guard let screen else { return }
        let notch = screen.notch
        var items: [ClosedRange<CGFloat>] = []
        if notch.hasNotch {
            let height = max(notch.rect.height, screen.frame.maxY - screen.visibleFrame.maxY)
            let bar = CGRect(x: screen.frame.minX, y: screen.frame.maxY - height, width: screen.frame.width, height: height)
            items = menuBar.frames
                .filter { bar.contains(CGPoint(x: $0.midX, y: $0.midY)) }
                .map { ($0.minX - notch.rect.midX) ... ($0.maxX - notch.rect.midX) }
        }
        if let simulatedMenuBarItems { items = simulatedMenuBarItems }
        guard items != model.menuBarItems else { return }
        if model.interaction == .expanded || model.interaction == .capture {
            withAnimation(Theme.snappy) { model.menuBarItems = items }
        } else {
            model.menuBarItems = items
        }
    }

    // MARK: Strand polish: menu bar icons that move while the island rests

    private var earsWatch: Task<Void, Never>?

    /// While the ears or a sneak show at rest, the icons beside the notch can change under them (a
    /// status item appears, or its text grows, and macOS moves it next to the notch): re-read
    /// where they sit when the ears appear and every 20 s while they stay (only the apps known to
    /// have icons, about 10 ms off the main thread).
    private func watchEars() {
        let atRest = model.presentation == .compact || model.presentation == .sneak
        if atRest, earsWatch == nil {
            menuBar.refresh()
            earsWatch = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(20))
                    guard !Task.isCancelled else { return }
                    self?.menuBar.refresh()
                }
            }
        } else if !atRest {
            earsWatch?.cancel()
            earsWatch = nil
        }
        withObservationTracking { _ = model.presentation } onChange: { [weak self] in
            Task { @MainActor in self?.watchEars() }
        }
    }

    /// The island in global AppKit coordinates for the current state.
    private var islandRect: CGRect {
        guard let screen else { return .zero }
        let size = model.layout.size
        let midX = screen.notch.rect.midX + model.layout.centerOffset
        return CGRect(x: midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height)
    }

    /// Where a press may pull the main character out: the island while it isn't open (closed,
    /// peeking, dictating), wider than the notch's own hot zone. Never quick capture: a click in
    /// its field that slid down a little pulled Tara out and closed it.
    func canPullFigure(at point: CGPoint) -> Bool {
        ![.expanded, .palette, .inbox, .capture].contains(model.interaction) && islandRect.insetBy(dx: -4, dy: -4).contains(point)
    }

    // MARK: Pointer

    func startMonitoring() {
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: moves.union(.leftMouseDown), handler: { [weak self] event in
            MainActor.assumeIsolated {
                if event.type == .leftMouseDown {
                    self?.dragBaseline = NSPasteboard(name: .drag).changeCount
                    self?.clickedOutside()
                } else {
                    self?.pointerMoved(dragging: event.type == .leftMouseDragged)
                }
            }
        }) { monitors.append(global) }
        // Clicks inside the panel: a short hold against collapsing right after.
        if let clicks = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
            MainActor.assumeIsolated {
                self?.lastPanelClick = Date()
                GazeCenter.shared.laugh()  // a click in the island or beside Tara: her eyes laugh
            }
            return event
        }) { monitors.append(clicks) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }) { monitors.append(local) }
        // Two-finger swipes reach the panel while the pointer is over the island.
        if let scroll = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handleScroll(event) ?? false }
            return consumed ? nil : event
        }) { monitors.append(scroll) }
        // The palette's and the inbox's keys, before the text field sees them.
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handleCommandKey(event) ?? false }
            return consumed ? nil : event
        }) { monitors.append(keys) }
    }

    /// The drag pasteboard's count at the last mouse down: a higher one means a drag started since.
    private var dragBaseline = NSPasteboard(name: .drag).changeCount
    /// Files dragged onto the closed notch: the app opens the shelf.
    var onFileDrag: (() -> Void)?

    /// A file drag is under way (from Finder, the desktop, a browser download …).
    private func isFileDrag() -> Bool {
        let board = NSPasteboard(name: .drag)
        // A file, or one a browser promises (a Gmail attachment out of Chrome).
        return board.changeCount != dragBaseline
            && board.types?.contains(where: { $0 == .fileURL || FileDrop.promiseTypes.contains($0) }) == true
    }

    /// Below this distance from the top edge a move at rest is ignored (well beyond the ears and
    /// the hover zone).
    static let farBelow: CGFloat = 140

    private func pointerMoved(dragging: Bool = false) {
        GazeCenter.shared.pointerMoved()  // Tara's eyes follow (throttled; nothing while none show)
        guard !wheelOpen, !isLocked, var screen else { return }
        let location = NSEvent.mouseLocation
        // "With pointer": at rest, the island follows the pointer to another display.
        if display() == .pointer, model.interaction == .rest, !screen.frame.contains(location),
           NSScreen.screens.contains(where: { $0.frame.contains(location) }) {
            place()
            guard let moved = self.screen else { return }
            screen = moved
        }
        // At rest with the pointer far below the top edge (most moves on the screen): nothing can
        // change, so the island's shape isn't worked out at all. Every move used to compute it,
        // which showed as several percent CPU while the mouse moved.
        if model.interaction == .rest, !pointerInside, !dragging, panel.ignoresMouseEvents,
           location.y < screen.frame.maxY - Self.farBelow {
            return
        }
        let island = islandRect
        let inside: Bool
        switch model.interaction {
        case .rest:
            // Enter on the notch itself (or the compact ears), with the usual edge tolerance.
            inside = NotchGeometry.hotZone(for: screen.notch.rect).contains(location) || island.contains(location)
        case .peek, .expanded, .capture, .palette, .inbox:
            // Stay zone: 30 pt around the visible shape.
            inside = island.insetBy(dx: -Self.stayMargin, dy: -Self.stayMargin).contains(location)
        }
        // Clicks are ours only over the shape itself; the margin stays clickable for other apps.
        panel.ignoresMouseEvents = !island.insetBy(dx: -4, dy: -4).contains(location)
            && !(model.interaction == .rest && inside)

        if inside, dragging, model.interaction != .expanded, model.modules.contains(where: { $0.kind == .tools }), onFileDrag != nil, isFileDrag() {
            // A file over the notch: straight to the shelf, held open until the drop.
            pointerInside = true
            onFileDrag?()
            expand(.tools, pinned: true)
            return
        }
        if inside {
            if !pointerInside, model.interaction == .rest, Date() > suppressUntil {
                Haptics.tick()  // immediate feedback; the peek itself waits for the dwell
            }
            pointerInside = true
            leaveTask?.cancel()
            leaveTask = nil
            if model.interaction == .expanded { pinned = false }
            if model.interaction == .rest, hoverTask == nil, Date() > suppressUntil {
                hoverTask = Task { [weak self] in
                    // Watching: a longer dwell, so passing the pointer by does nothing.
                    try? await Task.sleep(for: self?.model.watching == true ? .milliseconds(600) : Self.hoverDwell)
                    guard let self, !Task.isCancelled else { return }
                    self.hoverTask = nil
                    if self.model.interaction == .rest { self.set(.peek, animation: Theme.open) }
                    // Resting on: opens after the chosen time, without taking the keyboard (a
                    // click still opens at once). Not while watching.
                    guard let delay = self.hoverOpenDelay(), !self.model.watching else { return }
                    try? await Task.sleep(for: .seconds(max(0, delay - 0.2)))
                    guard !Task.isCancelled, self.pointerInside, self.model.interaction == .peek else { return }
                    self.expand()
                }
            }
        } else {
            pointerInside = false
            hoverTask?.cancel()
            hoverTask = nil
            // Something the island owns is open outside its shape (AirPlay picker): stay open.
            guard model.interaction != .rest, leaveTask == nil, !pinned, !IslandLock.shared.isLocked else { return }
            scheduleLeave()
        }
    }

    /// Collapses after the grace unless the pointer came back, a detail card is open, the panel
    /// was just clicked, or the user keeps it open until a click outside.
    private func scheduleLeave() {
        let expanded = model.interaction == .expanded
        if expanded && (keepsOpen() || model.current.holdsOpen) { return }
        let sinceClick = Date().timeIntervalSince(lastPanelClick)
        let delay = expanded ? max(Self.expandedLeaveGrace, Self.clickHold - sinceClick) : Self.leaveGrace
        leaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.leaveTask = nil
            guard !self.pointerInside, !IslandLock.shared.isLocked else { return }
            if self.model.interaction == .expanded, self.keepsOpen() || self.model.current.holdsOpen { return }
            self.collapse()
        }
    }

    // MARK: Swipes

    private var swipes = SwipeClassifier()

    /// Only on the island, and while it's open only on its top band, so scrolling content
    /// inside the panel stays scrolling.
    private func handleScroll(_ event: NSEvent) -> Bool {
        guard !wheelOpen, !isLocked, event.hasPreciseScrollingDeltas else { return false }
        let location = NSEvent.mouseLocation
        let island = islandRect
        guard island.insetBy(dx: -4, dy: -4).contains(location) else { return false }
        // The open panel, the palette's list and the inbox scroll below the notch band.
        if [.expanded, .palette, .inbox].contains(model.interaction),
           location.y < island.maxY - model.notchSize.height - 10 { return false }
        let phase: SwipeClassifier.Phase = switch event.phase {
        case .began: .began
        case .changed: .changed
        case .ended, .cancelled: .ended
        default: .other
        }
        if let swipe = swipes.feed(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                                   natural: event.isDirectionInvertedFromDevice, phase: phase,
                                   momentum: !event.momentumPhase.isEmpty) {
            perform(swipe)
        }
        return true
    }

    /// Down opens, up closes, sideways switches the module (and opens).
    func perform(_ swipe: SwipeClassifier.Swipe) {
        switch swipe {
        case .down:
            if model.interaction != .expanded { expand() }
        case .up:
            if model.interaction != .rest {
                Haptics.tick()
                collapse()
            }
        case .left, .right:
            let kinds = model.modules.map(\.kind)
            let index = kinds.firstIndex(of: model.module) ?? 0
            let step = swipe == .right ? 1 : -1
            model.direction = CGFloat(step)
            Haptics.tick()
            withAnimation(Theme.snappy) { model.module = kinds[(index + step + kinds.count) % kinds.count] }
            if model.interaction != .expanded { expand() }
        }
    }

    private func clickedOutside() {
        // Clicks into Apple's AirPlay picker land "outside" too; our own floating list closes
        // (its release re-checks the pointer and collapses as usual).
        guard !IslandLock.shared.isLocked else {
            IslandLock.shared.dismissOnOutsideClick()
            return
        }
        guard !isLocked, [.expanded, .palette, .inbox].contains(model.interaction),
              !islandRect.contains(NSEvent.mouseLocation) else { return }
        collapse()
    }

    // MARK: State changes

    private func set(_ interaction: NotchModel.Interaction, animation: Animation) {
        let wasExpanded = model.interaction == .expanded
        withAnimation(animation) { model.interaction = interaction }
        let isExpanded = interaction == .expanded
        if wasExpanded != isExpanded {
            for module in model.modules { module.setExpanded(isExpanded) }
        }
        if !isExpanded {
            if model.keyboardFocus { model.keyboardFocus = false }
            if panel.isKeyWindow { panel.resignKey() }
        }
        // A prompt that arrived while the palette was open shows once it has closed.
        if interaction != .palette, approvalWaiting {
            approvalWaiting = false
            if [.rest, .expanded].contains(interaction) {
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(300))
                    guard let self, [.rest, .expanded].contains(self.model.interaction), self.model.approvals?.current != nil else { return }
                    self.showApproval()
                }
            }
        }
        // The palette is gone once its island has closed or turned into something else.
        if interaction != .palette, model.palette != nil {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                if self?.model.interaction != .palette { self?.model.palette = nil }
            }
        }
        panel.ignoresMouseEvents = interaction == .rest && !islandRect.contains(NSEvent.mouseLocation)
    }

    /// Opens the panel on the current module (or `module`).
    func expand(_ module: ModuleKind? = nil, pinned: Bool = false) {
        guard Date() > suppressUntil || pinned else { return }
        hoverTask?.cancel()
        hoverTask = nil
        leaveTask?.cancel()
        leaveTask = nil
        if let module, module != model.module {
            // Already open: the island springs to the new tab's panel size instead of jumping.
            if model.interaction == .expanded {
                withAnimation(Theme.snappy) { model.module = module }
            } else {
                model.module = module
            }
        }
        self.pinned = pinned
        if model.interaction != .expanded {
            menuBar.refresh()
            Haptics.open()
            set(.expanded, animation: Theme.open)
        }
    }

    func collapse() {
        leaveTask?.cancel()
        leaveTask = nil
        pinned = false
        guard model.interaction != .rest else { return }
        set(.rest, animation: Theme.close)
        // Closed, the island keeps its tab for the next open (a setting), else goes back to the first.
        if !reopensLastTab() {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                guard let self, self.model.interaction == .rest, let first = self.model.modules.first?.kind else { return }
                self.model.module = first
            }
        }
        if model.capture != nil {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                if self?.model.interaction == .rest { self?.model.capture = nil }
            }
        }
        showNextSneak()
    }

    // MARK: Sneak peek

    private var sneaks = SneakQueue<Sneak>()
    private var sneakTask: Task<Void, Never>?

    /// Shows one line on the closed island for a moment. Events queue up; one with the same
    /// key replaces a waiting one. While the panel or the hover peek is open, the line waits.
    /// Updates held back while watching, for the summary when it ends.
    private(set) var heldWhileWatching = 0

    /// - Parameters:
    ///   - urgent: gets through Watch mode (approvals, a meeting about to start).
    ///   - counts: held back while watching, it counts toward "N updates while you watched".
    /// - Returns: whether the line shows or waits its turn; false when it was dropped.
    @discardableResult
    func sneak(_ sneak: Sneak, key: String, onlyAtRest: Bool = false, urgent: Bool = false, counts: Bool = true) -> Bool {
        // Some events are stale by the time the panel closes (a track change seen in the panel).
        if onlyAtRest && model.interaction != .rest { return false }
        guard Quiet.letsThrough(urgent: urgent, watching: model.watching) else {
            if counts { heldWhileWatching += 1 }
            return false
        }
        sneaks.push(sneak, key: key)
        showNextSneak()
        return true
    }

    private func showNextSneak() {
        guard sneakTask == nil, model.interaction == .rest, let next = sneaks.pop() else { return }
        withAnimation(Theme.open) { model.sneak = next.item }
        sneakTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(next.item.duration))
            guard let self else { return }
            if self.model.interaction == .rest {
                withAnimation(Theme.close) { self.model.sneak = nil }
            } else {
                self.model.sneak = nil
            }
            self.sneakTask = nil
            try? await Task.sleep(for: .milliseconds(350))
            self.showNextSneak()
        }
    }

    /// Watch mode changed: hide the ears softly; when it ends, one line for what waited.
    func setWatching(_ on: Bool) {
        withAnimation(.easeInOut(duration: 0.2)) { model.watching = on }
        if on {
            heldWhileWatching = 0
            if model.interaction != .expanded, model.sneak != nil { withAnimation(.easeInOut(duration: 0.2)) { model.sneak = nil } }
        } else if let line = Quiet.summary(heldWhileWatching) {
            heldWhileWatching = 0
            sneak(Sneak(visual: .dot, title: line, duration: 3.2),
                  key: "watch.summary")
        }
    }

    /// Recordings: the hover peek without moving the pointer.
    func tourPeek() {
        set(.peek, animation: Theme.open)
        pinned = true
        leaveTask?.cancel()
        leaveTask = nil
    }

    // MARK: Quick capture (design preview)

    /// A permission prompt arrived: open on it, with keyboard focus for ↵ / ⌘↵ / esc.
    func showApproval() {
        // The inbox shows it already, among the rest; the palette keeps its query and focus, and
        // the prompt waits until it closes.
        if model.interaction == .palette { approvalWaiting = true }
        guard ![.inbox, .palette].contains(model.interaction) else { return }
        expand(pinned: true)
        model.keyboardFocus = true
        panel.makeKey()
    }

    /// ⌃⌥N or the "+" in the panel: one field grows out of the notch, with keyboard focus.
    func openCapture(text: String = "") {
        hoverTask?.cancel()
        hoverTask = nil
        leaveTask?.cancel()
        leaveTask = nil
        pinned = true
        let capture = QuickCapture()
        capture.people = inbox.people
        capture.text = text
        model.capture = capture
        menuBar.refresh()
        Haptics.open()
        set(.capture, animation: Theme.open)
        model.keyboardFocus = true
        panel.makeKey()
    }

    /// Files the text (mock: nothing leaves the app), shows the confirmation, closes.
    func sendCapture() {
        guard let capture = model.capture, capture.phase == .editing,
              !capture.text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Haptics.confirm()
        if capture.dictating, let dictation = model.module(.dictation) as? DictationModule, dictation.isActive {
            dictation.stop()
        }
        capture.dictating = false
        Task { [weak self] in
            guard let self else { return }
            // Recordings (--preview) never touch the real queue or the hub.
            capture.outcome = self.model.previewFeatures
                ? .delivered
                : await self.inbox.file(text: capture.text, route: capture.route, parse: capture.parse)
            withAnimation(Theme.open) { capture.phase = .sent }
            // Long enough to read where it went and reach its buttons; with the pointer on it,
            // it stays until the pointer leaves.
            try? await Task.sleep(for: .seconds(3.2))
            guard self.model.capture === capture, self.model.interaction == .capture else { return }
            if self.pointerInside {
                self.pinned = false
            } else {
                self.collapse()
            }
        }
    }

    /// The confirmation's Notepad button: the Tools tab on the Notepad's "Tara's notes", where
    /// every capture shows. Without the Notepad, the Markdown inbox opens instead.
    func showCapturedNotes() {
        guard let tools = model.module(.tools) as? ToolsModule, tools.tabs.contains(.notes), let notes = tools.notes else {
            openCaptureInbox()
            return
        }
        Haptics.tick()
        tools.tab = .notes
        notes.showsTara = true
        expandWithFocus(.tools)
        model.capture = nil
    }

    /// The confirmation's file button: the Markdown inbox in its app (Obsidian for a vault).
    func openCaptureInbox() {
        guard let file = model.capture?.inboxFile else { return }
        Haptics.tick()
        CaptureInbox.openMarkdown(file)
        collapse()
    }

    /// "Add to Calendar": the text named a day and a time; a one-hour event in the default calendar.
    /// Calendar access is asked here, on the click, if macOS hasn't asked yet.
    func createCaptureEvent() {
        guard let capture = model.capture, capture.phase == .editing, let start = capture.eventStart else { return }
        let title = CaptureParser.title(removingDatesFrom: capture.text)
        Haptics.confirm()
        Task { [weak self] in
            guard let self else { return }
            let when = start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute().locale(Locale(identifier: "en_GB")))
            if self.model.previewFeatures {
                capture.eventAdded = "\(title.isEmpty ? "Event" : title) · \(when)"
            } else if let error = await CalendarWriter.add(title: title.isEmpty ? capture.text : title, start: start) {
                capture.outcome = .queued(reason: error)
            } else {
                capture.eventAdded = "\(title.isEmpty ? "Event" : title) · \(when)"
            }
            withAnimation(Theme.open) { capture.phase = .sent }
            try? await Task.sleep(for: .seconds(2.2))
            guard self.model.capture === capture else { return }
            self.collapse()
        }
    }

    /// The mic in the field: Wispr Flow hands-free; the text lands in the field, which has focus.
    func toggleCaptureMic() {
        guard let capture = model.capture else { return }
        Haptics.tick()
        if !model.previewFeatures, let dictation = model.module(.dictation) as? DictationModule {
            dictation.toggle()
        }
        withAnimation(Theme.snappy) { capture.dictating.toggle() }
    }

    /// A tap on the hardware notch: opens, or closes when already open.
    func tapNotch() {
        if model.interaction == .expanded {
            collapse()
            // The same mouse-up reaches the island's tap handler next; don't reopen.
            suppressUntil = Date().addingTimeInterval(0.3)
        } else {
            expandFromClick()
        }
    }

    /// A click on the notch or the closed island opens the panel with keyboard focus: ← → switch
    /// tabs, ↵ acts, esc closes. A hover alone never takes the keyboard from the app in front.
    private func expandFromClick() {
        expand()
        guard model.interaction == .expanded else { return }
        model.keyboardFocus = true
        panel.makeKey()
    }

    /// Opens on `module`, pinned and with keyboard focus (esc closes), for an open from outside
    /// the island, such as Tara's "Open the notch".
    func expandWithFocus(_ module: ModuleKind) {
        expand(module, pinned: true)
        guard model.interaction == .expanded else { return }
        model.keyboardFocus = true
        panel.makeKey()
    }

    /// ⌃⌥Space: open with keyboard focus, or close.
    func toggleFromKeyboard() {
        if model.interaction == .expanded {
            collapse()
            return
        }
        expand(pinned: true)
        model.keyboardFocus = true
        panel.makeKey()
    }

    /// The wheel picked a module.
    func show(_ module: ModuleKind) {
        if module == .dictation, let dictation = model.module(.dictation) as? DictationModule {
            // Dictation is an action: start it right away; the ears show that it's listening.
            dictation.start()
            collapse()
            return
        }
        expand(module, pinned: true)
    }

    // MARK: Wheel coordination

    func wheelWillOpen() {
        wheelOpen = true
        suppressUntil = .distantFuture
        hoverTask?.cancel()
        hoverTask = nil
        collapse()
    }

    func wheelDidClose() {
        wheelOpen = false
        // The release that ends the hold must not count as a click on the island.
        suppressUntil = Date().addingTimeInterval(0.35)
    }

    // MARK: Command palette and agents inbox

    /// A permission prompt arrived while the palette was open.
    private var approvalWaiting = false

    /// ⌃⌥K, or ⌘K while the island is open: the palette, or closed when it's showing.
    func togglePalette() {
        if model.interaction == .palette { collapse() } else { openPalette() }
    }

    /// Opens the palette with what every provider offers right now.
    func openPalette(query: String = "") {
        hoverTask?.cancel()
        hoverTask = nil
        leaveTask?.cancel()
        leaveTask = nil
        pinned = true
        let context = PaletteContext(show: { [weak self] kind in self?.show(kind) })
        let island = ClosurePaletteProvider { [weak self] in self?.islandItems($0) ?? [] }
        let providers: [any PaletteProvider] = [island] + model.modules.compactMap { $0 as? any PaletteProvider } + paletteSources.providers
        let palette = CommandPalette(items: providers.flatMap { $0.paletteItems(context) }, usage: paletteSources.usage,
                                     fallbacks: { [weak self] in self?.paletteFallbacks($0) ?? [] })
        palette.query = query
        model.palette = palette
        menuBar.refresh()
        Haptics.open()
        set(.palette, animation: Theme.open)
        model.keyboardFocus = true
        panel.makeKey()
    }

    /// ↵ (or a click) on a row; ⌘ for its second action. The palette closes unless the action
    /// opened something else in the island.
    func activatePalette(_ index: Int, secondary: Bool) {
        guard let palette = model.palette, palette.rows.indices.contains(index) else { return }
        let item = palette.rows[index].item
        palette.selection = index
        paletteSources.record(item.id)
        Haptics.confirm()
        (secondary ? item.secondary ?? item.perform : item.perform)()
        if model.interaction == .palette { collapse() }
    }

    /// The island's own items: its tabs, quick capture, the inbox, Watch mode, ask Tara.
    private func islandItems(_ context: PaletteContext) -> [PaletteItem] {
        var items = model.modules.map { module in
            PaletteItem(id: "tab:\(module.kind.rawValue)", title: Localization.string(module.kind.title), symbol: module.symbol,
                        kind: .tab, keywords: [module.kind.rawValue] + (module.kind == .calendar ? ["calendar", "meeting"] : []),
                        perform: { context.show(module.kind) })
        }
        if model.requestCapture != nil {
            items.append(PaletteItem(id: "capture", title: Localization.string("Quick capture"), subtitle: "⌃⌥N", symbol: "plus",
                                     kind: .action, keywords: ["note", "task", "todo"],
                                     perform: { [weak self] in self?.openCapture() }))
        }
        if let inbox = model.inbox, model.modules.contains(where: { $0.kind == .agents }) {
            let count = inbox.count
            items.append(PaletteItem(id: "inbox", title: Localization.string("Agents inbox"),
                                     subtitle: count > 0 ? String(format: Localization.string("%d need you"), count) : "⌃⌥A",
                                     symbol: "tray", kind: .action, keywords: ["approvals", "questions", "waiting"],
                                     priority: count > 0 ? 0.7 : 0, tint: count > 0 ? Theme.waiting : nil,
                                     perform: { [weak self] in self?.openInbox() }))
        }
        if let ask = paletteSources.askTara {
            items.append(PaletteItem(id: "ask-tara", title: Localization.string("Ask Tara"), subtitle: "⌃⌥T", symbol: "sparkle",
                                     kind: .action, keywords: ["question", "memory", "assistant"], perform: { ask("") }))
        }
        if let toggle = model.toggleWatch {
            items.append(PaletteItem(id: "watch", title: Localization.string(model.watching ? "Watch mode off" : "Watch mode on"),
                                     subtitle: "⌃⌥W", symbol: model.watching ? "moon.fill" : "moon", kind: .action,
                                     keywords: ["quiet", "focus", "video"], perform: toggle))
        }
        return items
    }

    /// With a query: hand it to Tara, or capture it as it is.
    private func paletteFallbacks(_ query: String) -> [PaletteItem] {
        guard !query.isEmpty else { return [] }
        var items: [PaletteItem] = []
        if let ask = paletteSources.askTara {
            items.append(PaletteItem(id: "ask-tara-query", title: Localization.string("Ask Tara “%@”").replacingOccurrences(of: "%@", with: query),
                                     symbol: "sparkle", kind: .action, perform: { ask(query) }))
        }
        if model.requestCapture != nil {
            items.append(PaletteItem(id: "capture-query", title: Localization.string("Capture “%@”").replacingOccurrences(of: "%@", with: query),
                                     symbol: "plus", kind: .action, perform: { [weak self] in self?.openCapture(text: query) }))
        }
        return items
    }

    /// ⌃⌥A: the inbox, or closed when it's showing.
    func toggleInbox() {
        if model.interaction == .inbox { collapse() } else { openInbox() }
    }

    func openInbox() {
        guard let inbox = model.inbox, model.modules.contains(where: { $0.kind == .agents }) else { return }
        hoverTask?.cancel()
        hoverTask = nil
        leaveTask?.cancel()
        leaveTask = nil
        pinned = true
        inbox.startRound()
        menuBar.refresh()
        Haptics.open()
        set(.inbox, animation: Theme.open)
        model.keyboardFocus = true
        panel.makeKey()
        if inbox.current == nil { inboxEmptied() }
    }

    /// ↵ (`primary`) or ⌘↵ on the inbox's front item: by key (`id` nil), or by the button of
    /// the card showing `id`.
    func inboxKey(primary: Bool, id: String? = nil) {
        guard let inbox = model.inbox else { return }
        switch primary ? inbox.primary(id) : inbox.openSession(id) {
        case .stay: if inbox.current == nil { inboxEmptied() }
        case .leave: collapse()
        case .show(let kind): expand(kind, pinned: true)
        }
    }

    /// Nothing left: the "nothing needs you" card for a moment, then closed. Skipped prompts
    /// still wait, so with those the inbox stays until esc.
    func inboxEmptied() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            guard let self, self.model.interaction == .inbox, let inbox = self.model.inbox,
                  inbox.current == nil, inbox.count == 0, !self.isLocked else { return }
            self.collapse()
        }
    }

    /// Keys for the palette and the inbox, ahead of the text field; ⌘K while the panel is open.
    private func handleCommandKey(_ event: NSEvent) -> Bool {
        guard event.window === panel else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let isK = event.charactersIgnoringModifiers?.lowercased() == "k"
        switch model.interaction {
        case .expanded:
            guard command, isK else { return false }
            openPalette()
            return true
        case .palette:
            guard let palette = model.palette else { return false }
            let control = flags.contains(.control)
            switch event.keyCode {
            case 125: palette.move(1)                                   // ↓
            case 126: palette.move(-1)                                  // ↑
            case 48: palette.move(flags.contains(.shift) ? -1 : 1)      // tab
            case 36, 76: activatePalette(palette.selection, secondary: command)
            case 53:                                                    // esc: the query first, then the palette
                if palette.query.isEmpty { collapse() } else { palette.query = "" }
            default:
                if control, event.charactersIgnoringModifiers == "n" { palette.move(1); return true }
                if control, event.charactersIgnoringModifiers == "p" { palette.move(-1); return true }
                if command, isK { collapse(); return true }
                return false
            }
            return true
        case .capture:
            // Task, Question, Note: tab and ⇧tab always, ← → while the field is empty (with
            // text the arrows move the cursor).
            guard let capture = model.capture, capture.phase == .editing else { return false }
            let step: Int
            switch event.keyCode {
            case 48: step = flags.contains(.shift) ? -1 : 1
            case 123 where capture.text.isEmpty && flags.isDisjoint(with: [.command, .option, .control]): step = -1
            case 124 where capture.text.isEmpty && flags.isDisjoint(with: [.command, .option, .control]): step = 1
            default: return false
            }
            capture.step(step)
            return true
        case .inbox:
            guard let inbox = model.inbox else { return false }
            switch event.keyCode {
            case 53:
                // Nothing in front (all clear, or all skipped): esc closes.
                guard inbox.current != nil else { collapse(); return true }
                inbox.skip()
                if inbox.current == nil { inboxEmptied() }
                return true
            case 36, 76:
                if command {
                    inboxKey(primary: false)
                    return true
                }
                // A question with a field takes ↵ itself (send).
                if case .approval(let pending)? = inbox.current?.source, pending.request.freeText { return false }
                inboxKey(primary: true)
                return true
            default:
                return false
            }
        default:
            return false
        }
    }

    // MARK: Keyboard

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if model.interaction == .capture {
            if press.key == .escape {
                collapse()
                return .handled
            }
            return .ignored
        }
        guard model.interaction == .expanded else { return .ignored }
        // A permission prompt: ↵ allow once, ⌘↵ allow for the session, esc deny.
        if let approvals = model.approvals, approvals.current != nil {
            switch press.key {
            case .return where press.modifiers.contains(.command): approvals.answer(.allowSession); return .handled
            case .return: approvals.answer(.allowOnce); return .handled
            case .escape: approvals.answer(.deny); return .handled
            default: return .ignored
            }
        }
        if model.current.handleKey(press) { return .handled }
        let kinds = model.modules.map(\.kind)
        let index = kinds.firstIndex(of: model.module) ?? 0
        switch press.key {
        case .escape:
            if !model.current.handleBack() { collapse() }
            return .handled
        case .leftArrow where model.current.handleBack():
            return .handled
        case .leftArrow, .rightArrow:
            let step = press.key == .rightArrow ? 1 : -1
            let next = (index + step + kinds.count) % kinds.count
            model.direction = CGFloat(step)
            Haptics.tick()
            withAnimation(Theme.snappy) { model.module = kinds[next] }
            return .handled
        case .return:
            model.current.primaryAction()
            return .handled
        default:
            if let digit = Int(press.characters), (1...kinds.count).contains(digit) {
                model.direction = digit - 1 > index ? 1 : -1
                withAnimation(Theme.snappy) { model.module = kinds[digit - 1] }
                    return .handled
            }
            return .ignored
        }
    }
}
