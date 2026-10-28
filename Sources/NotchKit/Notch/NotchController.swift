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
    static let stayMargin: CGFloat = 30
    private var pointerInside = false
    /// Demos and screenshots (`--expand`, `--tour`): ignore the real pointer so the states stay put.
    var isLocked = false
    /// Quick capture's destination (queue file, hub).
    let inbox = CaptureInbox()
    /// The menu bar icons, so the open island ends between them.
    private let menuBar = MenuBarExtras()

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
                    self?.expand()
                }
            },
            onKey: { [weak self] in self?.handleKey($0) ?? .ignored },
            onCaptureSend: { [weak self] in self?.sendCapture() },
            onCaptureMic: { [weak self] in self?.toggleCaptureMic() },
            onCaptureEvent: { [weak self] in self?.createCaptureEvent() }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.safeAreaRegions = []
        panel.contentView = hosting
        menuBar.onChange = { [weak self] in self?.fitToMenuBar() }
        place()
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
        guard items != model.menuBarItems else { return }
        if model.interaction == .expanded || model.interaction == .capture {
            withAnimation(Theme.snappy) { model.menuBarItems = items }
        } else {
            model.menuBarItems = items
        }
    }

    /// The island in global AppKit coordinates for the current state.
    private var islandRect: CGRect {
        guard let screen else { return .zero }
        let size = model.layout.size
        let midX = screen.notch.rect.midX
        return CGRect(x: midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height)
    }

    /// Where a press may pull the main character out: the island while it isn't open (closed,
    /// peeking, dictating), wider than the notch's own hot zone.
    func canPullFigure(at point: CGPoint) -> Bool {
        model.interaction != .expanded && islandRect.insetBy(dx: -4, dy: -4).contains(point)
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
            MainActor.assumeIsolated { self?.lastPanelClick = Date() }
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
    }

    /// The drag pasteboard's count at the last mouse down: a higher one means a drag started since.
    private var dragBaseline = NSPasteboard(name: .drag).changeCount
    /// Files dragged onto the closed notch: the app opens the shelf.
    var onFileDrag: (() -> Void)?

    /// A file drag is under way (from Finder, the desktop, a browser download …).
    private func isFileDrag() -> Bool {
        let board = NSPasteboard(name: .drag)
        return board.changeCount != dragBaseline && board.types?.contains(.fileURL) == true
    }

    private func pointerMoved(dragging: Bool = false) {
        guard !wheelOpen, !isLocked, var screen else { return }
        let location = NSEvent.mouseLocation
        // "With pointer": at rest, the island follows the pointer to another display.
        if display() == .pointer, model.interaction == .rest, !screen.frame.contains(location),
           NSScreen.screens.contains(where: { $0.frame.contains(location) }) {
            place()
            guard let moved = self.screen else { return }
            screen = moved
        }
        let island = islandRect
        let inside: Bool
        switch model.interaction {
        case .rest:
            // Enter on the notch itself (or the compact ears), with the usual edge tolerance.
            inside = NotchGeometry.hotZone(for: screen.notch.rect).contains(location) || island.contains(location)
        case .peek, .expanded, .capture:
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
        if model.interaction == .expanded, location.y < island.maxY - model.notchSize.height - 10 { return false }
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
        guard !isLocked, model.interaction == .expanded, !islandRect.contains(NSEvent.mouseLocation) else { return }
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
            model.module = module
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
        // Closed, the island goes back to the first tab, so it opens there next time.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let self, self.model.interaction == .rest, let first = self.model.modules.first?.kind else { return }
            self.model.module = first
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
        expand(pinned: true)
        model.keyboardFocus = true
        panel.makeKey()
    }

    /// ⌃⌥N or the "+" in the panel: one field grows out of the notch, with keyboard focus.
    func openCapture() {
        hoverTask?.cancel()
        hoverTask = nil
        leaveTask?.cancel()
        leaveTask = nil
        pinned = true
        let capture = QuickCapture()
        capture.people = inbox.people
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
            try? await Task.sleep(for: .seconds(capture.outcome == .delivered ? 1.8 : 2.6))
            guard self.model.capture === capture else { return }
            self.collapse()
        }
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
            expand()
        }
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
