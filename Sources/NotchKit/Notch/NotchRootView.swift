import NotchCore
import SwiftUI

/// The island hanging from the top edge of the screen. Everything grows out of the black notch:
/// one shape whose size and corner radii spring between closed, compact, peek and expanded.
struct NotchRootView: View {
    static let space = "island"

    let model: NotchModel
    /// Called by the shell when the island is clicked outside of a control (expand).
    let onTapIsland: () -> Void
    let onKey: (KeyPress) -> KeyPress.Result
    var onCaptureSend: () -> Void = {}
    var onCaptureMic: () -> Void = {}
    var onCaptureEvent: () -> Void = {}
    /// The confirmation's buttons: the Notepad on "Tara's notes", or the Markdown inbox.
    var onCaptureShowNotes: () -> Void = {}
    var onCaptureOpenInbox: () -> Void = {}
    /// A palette row was clicked (or ↵): its index, and whether ⌘ was held.
    var onPaletteActivate: (Int, Bool) -> Void = { _, _ in }
    /// The inbox card's own button: ↵ (true) or ⌘↵, and the id of the item it shows.
    var onInboxKey: (Bool, String) -> Void = { _, _ in }
    /// The inbox ran out while open (the last prompt answered by click).
    var onInboxEmpty: () -> Void = {}

    @Namespace private var namespace
    @FocusState private var focused: Bool
    /// Each opening of the peek: the figures nudge once, staggered (`FigureNudge`).
    @State private var figureCue = 0

    var body: some View {
        let layout = model.layout
        VStack(spacing: 0) {
            island(layout)
                .frame(width: layout.size.width, height: layout.size.height, alignment: .top)
                .background(
                    NotchShape(topRadius: layout.topRadius, bottomRadius: layout.bottomRadius)
                        .fill(Color.black)
                        .shadow(color: .black.opacity([.expanded, .palette, .inbox].contains(layout.presentation) ? 0.55 : 0),
                                radius: 22, y: 10)
                )
                .clipShape(NotchShape(topRadius: layout.topRadius, bottomRadius: layout.bottomRadius))
                .coordinateSpace(.named(Self.space))
                .environment(\.notch, NotchEnvironment(namespace: namespace))
                .environment(\.figuresHidden, model.watching)
                .environment(\.quietEars, !model.detailedEars)
                .environment(\.taraResting, ![.expanded, .palette, .inbox, .capture].contains(layout.presentation) && model.taraResting)
                .environment(\.figureCue, figureCue)
                .environment(\.handlePressed, model.handlePressed)
                .contentShape(NotchShape(topRadius: layout.topRadius, bottomRadius: layout.bottomRadius))
                .onTapGesture { if ![.expanded, .palette, .inbox].contains(model.interaction) { onTapIsland() } }
                // One ear at rest (the quiet look): the island grows to the left only.
                .offset(x: layout.centerOffset)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Watch mode at rest: nothing at all, also no pill over a fullscreen video on a display
        // without a notch. A hover or an urgent line brings the island back.
        .opacity(model.watching && model.interaction == .rest && model.sneak == nil ? 0 : 1)
        // Ears come and go softly when attention or Watch mode changes.
        .animation(.easeInOut(duration: 0.2), value: model.presentation)
        .environment(\.colorScheme, .dark)
        .focusable(model.keyboardFocus)
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: .down) { onKey($0) }
        .onChange(of: model.keyboardFocus) { _, focus in focused = focus }
        .onChange(of: model.presentation) { _, now in if now == .peek { figureCue += 1 } }
    }

    /// Right-click on the island at rest or hovered: pause Tara's memory, or resume it.
    @ViewBuilder private var memoryMenu: some View {
        if model.memoryPaused, let resume = model.resumeMemory {
            Button("Resume Tara's memory", action: resume)
        } else if let pause = model.pauseMemory {
            ForEach(MemoryPause.allCases, id: \.self) { length in
                Button(LocalizedStringKey(length.title)) { pause(length) }
            }
        }
    }

    /// Tara at rest and in the peek, drawn once over the ears and the peek line (they keep her
    /// place free): from rest to the peek she moves and grows as one figure, whole, instead of a
    /// second copy crossing over one that the ear cut off.
    @ViewBuilder
    private func islandTara(_ layout: NotchLayout, peek: Bool) -> some View {
        if let agents = (peek ? model.peekModule : model.earModule) as? AgentsModule {
            let box = layout.taraBox
            IslandTara(module: agents, height: box.height)
                .frame(width: box.width, height: box.height, alignment: .bottom)
                .notchMatched("agents.main", in: namespace)
                .padding(.leading, box.minX)
                .padding(.top, box.minY)
        }
    }

    @ViewBuilder
    private func island(_ layout: NotchLayout) -> some View {
        let notch = model.notchSize
        ZStack(alignment: .top) {
            switch layout.presentation {
            case .closed:
                Color.clear
            case .capture:
                if let capture = model.capture {
                    CaptureView(capture: capture, cast: model.cast, notch: notch,
                                onSend: onCaptureSend, onMic: onCaptureMic, onEvent: onCaptureEvent,
                                onShowNotes: onCaptureShowNotes, onOpenInbox: onCaptureOpenInbox)
                        .padding(.horizontal, layout.topRadius)
                        .transition(.blurSlide(y: -12, scale: 0.94))
                }
            case .palette:
                if let palette = model.palette {
                    PaletteView(palette: palette, notch: notch, onActivate: onPaletteActivate)
                        .padding(.horizontal, layout.topRadius)
                        .transition(.blurSlide(y: -12, scale: 0.94))
                }
            case .inbox:
                if let inbox = model.inbox {
                    InboxView(inbox: inbox, notch: notch, onKey: onInboxKey, onEmpty: onInboxEmpty)
                        .padding(.horizontal, layout.topRadius)
                        .transition(.blurSlide(y: -14, scale: 0.94))
                }
            case .sneak:
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        // The sneak line carries the figure; the left ear stays empty meanwhile.
                        Color.clear.frame(maxWidth: .infinity)
                        Color.clear.frame(width: notch.width)
                        // Watch mode: the breakthrough line alone, no ear beside it; nor where an
                        // icon sits next to the notch, nor in the quiet look.
                        if model.watching || !model.detailedEars || layout.earRoom < NotchLayout.minEarWidth {
                            Color.clear.frame(maxWidth: .infinity)
                        } else {
                            model.earModule.trailingEar(peek: false).frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: notch.height)
                    if let sneak = model.sneak {
                        SneakLine(sneak: sneak, cast: model.cast)
                            .padding(.horizontal, 12)
                            .frame(maxHeight: .infinity)
                            .id(sneak)
                            .transition(.blurSlide(y: -6, scale: 0.96))
                    }
                }
                .padding(.horizontal, layout.topRadius)
                .transition(.blurSlide(scale: 0.9))
            case .compact where layout.showsCue:
                // No room for ears beside the notch: a short mark under it instead, in Tara's
                // colour while something needs the user.
                Capsule()
                    .fill(!model.earModule.needsAttention ? Theme.textSecondary : TaraAccent.shared.color)
                    .frame(width: 18, height: 3)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 2)
                    .transition(.opacity)
            case .compact, .peek:
                let ears = model.earModule
                let isPeek = layout.presentation == .peek
                // The quiet look at rest, and its peek while Tara is hovered: the left ear alone (the
                // island has no room for a right one).
                let oneEar = layout.oneEar && (!isPeek || layout.peek != .line)
                // The peek's ears are as narrow as the compact ones unless the menu bar has room.
                let roomyEars = isPeek && layout.besideNotch >= 56
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ears.leadingEar(peek: roomyEars)
                            .environment(\.islandPeek, isPeek)
                            .frame(maxWidth: .infinity)
                            .clipped()
                        Color.clear.frame(width: notch.width)
                        if !oneEar {
                            ears.trailingEar(peek: roomyEars)
                                .environment(\.figureOrder, 1)
                                .frame(maxWidth: .infinity)
                                .clipped()
                        }
                    }
                    .frame(height: notch.height)
                    if isPeek && layout.peek != .ear {
                        model.peekModule.peekLine()
                            .padding(.horizontal, 12)
                            .frame(maxHeight: .infinity)
                            .transition(.blurSlide(y: -6, scale: 0.96))
                    }
                }
                .padding(.horizontal, layout.topRadius)
                .overlay(alignment: .topLeading) { islandTara(layout, peek: isPeek) }
                // No separate mark for screen context or the pause: Tara is the mark (awake while
                // screen context reads, dimmed and asleep while paused or off; `taraResting`).
                // Right-click pauses or resumes her memory.
                .contextMenu { memoryMenu }
                // Watch mode on: a tiny moon, only while hovered.
                .overlay(alignment: .bottomTrailing) {
                    if isPeek && model.watching {
                        Image(systemName: "moon.fill").font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.trailing, layout.topRadius + 8)
                            .padding(.bottom, 5)
                            .help("Watch mode is on (⌃⌥W)")
                    }
                }
                .transition(.blurSlide(scale: 0.9))
            case .expanded:
                VStack(spacing: 0) {
                    // Fixed halves beside the notch: what doesn't fit shortens (never pushes the
                    // panel wider, which used to shift and clip the whole body).
                    let side = max(0, (layout.innerWidth - notch.width) / 2)
                    // Tabs that don't fit left of the notch continue right of it, before the status.
                    // Each panel size splits for its own width; on a size change the tabs glide
                    // with the island's edge.
                    let fit = TabStrip.fitting(in: side - 10)
                    let split = model.modules.count > fit
                    HStack(spacing: 0) {
                        TabStrip(model: model, range: split ? 0..<fit : nil)
                            .padding(.leading, 10)
                            .frame(width: side, alignment: .leading)
                        Color.clear.frame(width: notch.width)
                        HStack(spacing: 0) {
                            if split {
                                TabStrip(model: model, range: fit..<model.modules.count)
                                    .padding(.leading, 8)
                            }
                            Spacer(minLength: 4)
                            // The status takes the room it needs before the gap does (the plan
                            // limits keep their names where they fit).
                            StatusStrip(model: model)
                                .padding(.trailing, 12)
                                .padding(.leading, split ? 0 : 8)
                                .layoutPriority(1)
                        }
                        .frame(width: side)
                    }
                    .frame(height: notch.height)

                    ZStack {
                        if let approvals = model.approvals, let pending = approvals.current {
                            ApprovalCard(center: approvals, pending: pending, agents: model.module(.agents) as? AgentsModule)
                                .id(pending.id)
                                .transition(.blurSlide(y: -10))
                        } else {
                            model.current.body()
                                .id(model.module)
                                .transition(.blurSlide(x: 22 * model.direction))
                        }
                    }
                    // A fixed width: a module whose content asks for more truncates inside it
                    // instead of widening the panel (which shifted and clipped everything).
                    .frame(width: max(0, layout.innerWidth - 2 * NotchLayout.sideInset))
                    .padding(.top, NotchLayout.bodyTop)
                    .padding(.bottom, NotchLayout.bodyBottom)
                    .padding(.horizontal, NotchLayout.sideInset)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .clipped()
                }
                .padding(.horizontal, layout.topRadius)
                .transition(.blurSlide(y: -14, scale: 0.94))
            }
        }
    }
}

/// Compact module switcher in the left ear: small icons, a gliding highlight, live counts.
private struct TabStrip: View {
    let model: NotchModel
    /// Only these tabs (by position); `nil` = all, with the "+" and the moon when they fit.
    var range: Range<Int>?
    @Namespace private var tabs
    /// Press and hold a tab, then drag it sideways: it swaps places as it passes its neighbours.
    @State private var dragging: ModuleKind?
    /// Drag distance already spent on swaps; the rest is the tab's offset under the pointer.
    @State private var spent: CGFloat = 0
    @State private var offset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// One tab's width, measured: dragging this far moves a tab by one place.
    @State private var step: CGFloat = 28

    /// Width of one tab in a split strip (icon, padding 5, spacing); a count adds a little.
    static let splitTab: CGFloat = 28

    /// How many tabs fit in `width` when the strip is split around the notch.
    static func fitting(in width: CGFloat) -> Int { max(1, Int((width - 14) / splitTab)) }

    private var shown: [NotchModule] {
        guard let range else { return model.modules }
        return range.clamped(to: model.modules.indices).map { model.modules[$0] }
    }

    /// The full strip if it fits; else tighter, without the moon, without the counts. Quick
    /// capture's "+" stays to the end: it is the one button people look for. Split around the
    /// notch, the part right of it carries the "+" and the paused badge, which every full strip
    /// shows.
    var body: some View {
        if let range {
            let last = range.upperBound >= model.modules.count
            strip(counts: true, plus: last, moon: false, padding: 5, badge: last)
        } else {
            full
        }
    }

    private var full: some View {
        ViewThatFits(in: .horizontal) {
            strip(counts: true, plus: true, moon: true, padding: 8)
            strip(counts: true, plus: true, moon: false, padding: 6)
            strip(counts: false, plus: true, moon: false, padding: 5)
            strip(counts: false, plus: true, moon: false, padding: 3)
            strip(counts: false, plus: false, moon: false, padding: 3)
        }
    }

    private func strip(counts: Bool, plus showsPlus: Bool, moon showsMoon: Bool, padding: CGFloat,
                       badge: Bool = true) -> some View {
        HStack(spacing: 2) {
            ForEach(shown, id: \.kind) { module in
                let selected = module.kind == model.module
                Button {
                    select(module.kind)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: module.symbol)
                            .font(.system(size: 11.5, weight: .semibold))
                        if counts, let count = module.count {
                            Text("\(count)")
                                .font(Theme.font(11.5, .semibold).monospacedDigit())
                                .contentTransition(.numericText())
                        }
                    }
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                    .padding(.horizontal, padding)
                    .frame(height: 22)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(0.12))
                                .matchedGeometryEffect(id: "tab", in: tabs)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressScale())
                .offset(x: dragging == module.kind ? offset : 0)
                .zIndex(dragging == module.kind ? 1 : 0)
                .scaleEffect(dragging == module.kind && !reduceMotion ? 1.08 : 1)
                .simultaneousGesture(reorderGesture(module.kind))
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                    if module.kind == model.module { step = width + 2 }
                }
                // The hover tooltip also says that tabs can be moved: hold, then drag.
                .help(Text(LocalizedStringKey(module.kind.title)) + Text(verbatim: " · ") + Text("Hold and drag to move"))
                .accessibilityLabel(module.kind.title)
                .accessibilityHint(Text("Hold and drag to move"))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            if badge && model.memoryPaused { paused }
            if showsPlus { plus }
            if showsMoon { moon }
        }
        .fixedSize()
    }

    /// Quick capture.
    @ViewBuilder var plus: some View {
        if let request = model.requestCapture {
            Button(action: request) {
                Image(systemName: "plus")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressScale())
            .help("Quick capture (⌃⌥N)")
        }
    }

    /// Tara's memory is paused; a click resumes it.
    @ViewBuilder var paused: some View {
        Button { model.resumeMemory?() } label: {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .padding(.vertical, -3)  // a 28 pt target in the 22 pt strip
        .transition(.opacity)
        .help("Tara's memory is paused. Click to resume")
        .accessibilityLabel(Text("Tara's memory is paused"))
        .accessibilityHint(Text("Resumes it"))
    }

    /// Watch mode on or off.
    @ViewBuilder var moon: some View {
        if let toggle = model.toggleWatch {
            Button(action: toggle) {
                Image(systemName: model.watching ? "moon.fill" : "moon")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(model.watching ? Theme.accent : Theme.textSecondary)
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressScale())
            .help(model.watching ? "Watch mode is on (⌃⌥W)" : "Watch mode: keep the notch quiet (⌃⌥W)")
        }
    }

    private func reorderGesture(_ kind: ModuleKind) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if dragging == nil {
                    dragging = kind
                    spent = 0
                    Haptics.tick()
                }
                guard let drag else { return }
                var rest = drag.translation.width - spent
                if abs(rest) > step * 0.6, move(kind, by: rest > 0 ? 1 : -1) {
                    spent += rest > 0 ? step : -step
                    rest = drag.translation.width - spent
                }
                offset = rest
            }
            .onEnded { _ in
                guard dragging != nil else { return }
                withAnimation(reduceMotion ? nil : Theme.snappy) {
                    dragging = nil
                    offset = 0
                }
                spent = 0
                model.onReorder?(model.modules.map(\.kind))
            }
    }

    /// Moves the dragged tab one place; `false` at either end.
    private func move(_ kind: ModuleKind, by step: Int) -> Bool {
        guard let from = model.modules.firstIndex(where: { $0.kind == kind }) else { return false }
        let to = from + step
        guard model.modules.indices.contains(to) else { return false }
        withAnimation(reduceMotion ? nil : Theme.snappy) { model.modules.swapAt(from, to) }
        Haptics.tick()
        return true
    }

    private func select(_ kind: ModuleKind) {
        guard kind != model.module else { return }
        let from = model.modules.firstIndex { $0.kind == model.module } ?? 0
        let to = model.modules.firstIndex { $0.kind == kind } ?? 0
        model.direction = to > from ? 1 : -1
        Haptics.tick()
        withAnimation(Theme.snappy) { model.module = kind }
    }
}

/// Right ear: what the system is doing at a glance.
private struct StatusStrip: View {
    let model: NotchModel

    var body: some View {
        HStack(spacing: 10) {
            if let dictation = model.module(.dictation) as? DictationModule, dictation.isActive {
                ListeningGlyph(active: dictation.phaseIsListening, size: 13)
            }
            if model.module == .agents, let agents = model.module(.agents) as? AgentsModule {
                PlanBadge(module: agents)
                    .transition(.blurSlide(y: -4))
            } else if let agents = model.module(.agents) as? AgentsModule, !agents.snapshot.loops.isEmpty {
                let failed = agents.failedLoops.count
                let late = agents.snapshot.loops.filter { $0.isLate || $0.last?.status == .degraded }.count
                let full = failed > 0 ? "\(failed) loop failed" : late > 0 ? late == 1 ? "1 loop needs a look" : "\(late) loops need a look" : "Loops ok"
                let short = failed > 0 ? "\(failed) failed" : late > 0 ? "\(late) to check" : "Loops ok"
                let dot = Circle()
                    .fill(failed > 0 ? Theme.critical : late > 0 ? Theme.waiting : Theme.ok)
                    .frame(width: 6, height: 6)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 5) { dot; Text(full) }.fixedSize()
                    HStack(spacing: 5) { dot; Text(short) }.fixedSize()
                    dot
                }
                .font(Theme.font(12, .medium))
                .foregroundStyle(Theme.textSecondary)
                .help("\(full) · \(agents.snapshot.loops.count) loops")
            }
        }
        .lineLimit(1)
    }
}
