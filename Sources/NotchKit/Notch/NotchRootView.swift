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

    @Namespace private var namespace
    @FocusState private var focused: Bool

    var body: some View {
        let layout = model.layout
        VStack(spacing: 0) {
            island(layout)
                .frame(width: layout.size.width, height: layout.size.height, alignment: .top)
                .background(
                    NotchShape(topRadius: layout.topRadius, bottomRadius: layout.bottomRadius)
                        .fill(Color.black)
                        .shadow(color: .black.opacity(layout.presentation == .expanded ? 0.55 : 0),
                                radius: 22, y: 10)
                )
                .clipShape(NotchShape(topRadius: layout.topRadius, bottomRadius: layout.bottomRadius))
                .coordinateSpace(.named(Self.space))
                .environment(\.notch, NotchEnvironment(namespace: namespace))
                .environment(\.figuresHidden, model.watching)
                .contentShape(NotchShape(topRadius: layout.topRadius, bottomRadius: layout.bottomRadius))
                .onTapGesture { if model.interaction != .expanded { onTapIsland() } }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Ears come and go softly when attention or Watch mode changes.
        .animation(.easeInOut(duration: 0.2), value: model.presentation)
        .environment(\.colorScheme, .dark)
        .focusable(model.keyboardFocus)
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: .down) { onKey($0) }
        .onChange(of: model.keyboardFocus) { _, focus in focused = focus }
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
                                onSend: onCaptureSend, onMic: onCaptureMic, onEvent: onCaptureEvent)
                        .padding(.horizontal, layout.topRadius)
                        .transition(.blurSlide(y: -12, scale: 0.94))
                }
            case .sneak:
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        // The sneak line carries the figure; the left ear stays empty meanwhile.
                        Color.clear.frame(maxWidth: .infinity)
                        Color.clear.frame(width: notch.width)
                        // Watch mode: the breakthrough line alone, no ear beside it.
                        if model.watching {
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
            case .compact, .peek:
                let ears = model.earModule
                let isPeek = layout.presentation == .peek
                // The peek's ears are as narrow as the compact ones unless the menu bar has room.
                let roomyEars = isPeek && layout.besideNotch >= 56
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ears.leadingEar(peek: roomyEars)
                            .frame(maxWidth: .infinity)
                            .clipped()
                        Color.clear.frame(width: notch.width)
                        ears.trailingEar(peek: roomyEars)
                            .frame(maxWidth: .infinity)
                            .clipped()
                    }
                    .frame(height: notch.height)
                    if isPeek {
                        ears.peekLine()
                            .padding(.horizontal, 12)
                            .frame(maxHeight: .infinity)
                            .transition(.blurSlide(y: -6, scale: 0.96))
                    }
                }
                .padding(.horizontal, layout.topRadius)
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
                    HStack(spacing: 0) {
                        TabStrip(model: model)
                            .padding(.leading, 10)
                            .frame(width: side, alignment: .leading)
                        Color.clear.frame(width: notch.width)
                        StatusStrip(model: model)
                            .padding(.trailing, 12)
                            .padding(.leading, 8)
                            .frame(width: side, alignment: .trailing)
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
    @Namespace private var tabs

    /// The full strip if it fits; else without "+" and tighter; else without the counts.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            strip(counts: true, plus: true, padding: 8)
            strip(counts: true, plus: false, padding: 6)
            strip(counts: false, plus: false, padding: 5)
            strip(counts: false, plus: false, padding: 3)
        }
    }

    private func strip(counts: Bool, plus showsPlus: Bool, padding: CGFloat) -> some View {
        HStack(spacing: 2) {
            ForEach(model.modules, id: \.kind) { module in
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
                .help(module.kind.title)
                .accessibilityLabel(module.kind.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            if showsPlus { plus }
        }
        .fixedSize()
    }

    /// Quick capture (design preview).
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
            } else if let agents = model.module(.agents) as? AgentsModule {
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
