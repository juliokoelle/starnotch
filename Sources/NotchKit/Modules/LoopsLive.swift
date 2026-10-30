import AppKit
import NotchCore
import SwiftUI

// Loops: small silver faces (characters belong to sessions), a stripe per state (green running,
// orange needs a look, red failed, grey done), a list, today's timeline, and a detail card.

/// A loop's face: silver, eyes by state, a thin progress line while it runs.
struct LoopFace: View {
    let loop: AgentSnapshot.LoopStatus
    let phase: AgentsModule.LoopPhase
    var size: CGFloat = 14

    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 2) {
            if AvatarLibrary.shared.character("astra") != nil {
                // The Starnotch star, its colour and face by status.
                AvatarView(character: "astra", mood: .idle, height: size * 1.25, colorway: look.colorway,
                           emergeOnAppear: false, alive: false, level: look.level, forcedState: look.state)
                    .frame(width: size * 1.3, height: size * 1.25)
                    .scaleEffect(phase == .running && pulse ? 1.08 : 1)
                    .animation(phase == .running && !reduceMotion
                               ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: pulse)
                    .onAppear { if phase == .running { pulse = true } }
            } else {
                AgentFace(color: AgentsModule.loopColor, mood: phase.faceMood, size: size,
                          showsBadge: phase == .failed || phase == .waiting)
            }
            if phase == .running {
                ProgressLine(progress: loop.progress ?? runningGuess)
                    .frame(width: size, height: 2)
            }
        }
    }

    /// ok (ran today) Mint and happy, needs a look Sol and surprised, failed Rosé and angry,
    /// running Nova at work, otherwise a quiet greyed Cosmo, asleep.
    private var look: (level: PerformanceLevel, state: String, colorway: Colorway) {
        switch phase {
        case .running: return (.medium, "working", Colorway())
        case .waiting: return (.max, "surprised", Colorway())
        case .failed: return (.ultra, "angry", Colorway())
        case .done:
            let today = loop.last.map { $0.day == AgentScanner.day(Date()) && $0.status == .ok } ?? false
            return today ? (.low, "happy", Colorway()) : (.xhigh, "sleepy", Colorway(saturation: 0.25, brightness: 0.05))
        }
    }

    /// Without a reported progress, a slow fill over ten minutes keeps the line alive.
    private var runningGuess: Double {
        guard let since = loop.runningSince else { return 0.3 }
        return min(0.9, Date().timeIntervalSince(since) / 600)
    }
}

/// The strip under the side card: every face opens its loop.
struct LoopStrip: View {
    let module: AgentsModule

    /// Narrow side card: the next run goes first, then faces (the list has them all).
    var body: some View {
        ViewThatFits(in: .horizontal) {
            strip(faces: 8, showsNext: true)
            strip(faces: 8, showsNext: false)
            strip(faces: 6, showsNext: false)
            strip(faces: 4, showsNext: false)
        }
    }

    private func strip(faces: Int, showsNext: Bool) -> some View {
        HStack(spacing: 6) {
            // "Loops ›" opens the overview; a star opens its loop.
            HoverRow(cornerRadius: 7, help: "All loops") {
                module.openLoopsOverview()
            } label: {
                HStack(spacing: 3) {
                    Text("Loops")
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                }
                .font(Theme.font(12, .medium))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 6)
                .frame(height: 22)
                .fixedSize()
            }
            HStack(spacing: 2) {
                ForEach(module.loops.prefix(faces)) { loop in
                    let phase = module.phase(of: loop)
                    HoverRow(cornerRadius: 6, hoverOpacity: 0.12,
                             help: "\(loop.displayName) · \(phase.word)\(loop.last.map { ", \(TimeText.day($0.day))" } ?? "")") {
                        module.openLoop(loop.name)
                    } label: {
                        LoopFace(loop: loop, phase: phase, size: 14)
                            .frame(width: 22, height: 22)
                    }
                }
            }
            if module.loops.isEmpty {
                // "Loops ›" opens the overview, which explains how to get one.
                Text("none yet · how to add one")
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize()
            }
            Spacer(minLength: 4)
            if showsNext, let next = module.loops.compactMap(\.nextRun).min() {
                Text("next \(TimeText.clock(next))")
                    .font(Theme.font(12).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
    }
}

/// The loops overview without loops: what a loop is and the two steps to get one.
private struct LoopsEmpty: View {
    static let guide = URL(string: "https://github.com/juliokoelle/starnotch/blob/main/docs/SDK.md#connectors")

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                Text("No loops yet")
                    .font(Theme.font(14, .semibold)).foregroundStyle(Theme.textPrimary)
                Text("A loop is a job that runs on its own on a schedule: a nightly backup, a morning briefing, a sync. Each one shows here as a small star: running, done, needs a look, failed.")
                    .font(Theme.font(12.5)).foregroundStyle(Theme.textBody)
                    .fixedSize(horizontal: false, vertical: true)
                step(1, "A connector lists your jobs", "A small Swift package with a JobsProvider: name, schedule, the last runs.")
                step(2, "Each run reports live", "From the job itself, through the status API:")
                Text(#"open -g "starnotch://status?loop=backup&state=ok""#)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.textBody)
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.leading, 26)
                if let guide = Self.guide {
                    HoverRow(cornerRadius: 8, restOpacity: 0.07, hoverOpacity: 0.13, help: guide.absoluteString) {
                        NSWorkspace.shared.open(guide)
                    } label: {
                        HStack(spacing: 5) {
                            Text("Open the guide")
                            Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                        }
                        .font(Theme.font(12, .medium)).foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 10).frame(height: 26)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(Theme.font(11, .bold)).foregroundStyle(Theme.accent)
                .frame(width: 18, height: 18)
                .background(Theme.accent.opacity(0.16), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.font(12.5, .semibold)).foregroundStyle(Theme.textPrimary)
                Text(detail).font(Theme.font(12)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One row per loop: stripe, face, name, when, last action.
struct LoopRows: View {
    let module: AgentsModule
    var limit: Int?

    var body: some View {
        let loops = limit.map { Array(module.loops.prefix($0)) } ?? module.loops
        VStack(spacing: 4) {
            ForEach(loops) { loop in
                LoopRow(module: module, loop: loop)
            }
        }
    }
}

struct LoopRow: View {
    let module: AgentsModule
    let loop: AgentSnapshot.LoopStatus

    var body: some View {
        let phase = module.phase(of: loop)
        HoverRow(cornerRadius: 10, restOpacity: 0, hoverOpacity: 0.06,
                 help: "\(loop.displayName) · \(phase.word)") {
            module.openLoop(loop.name)
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(phase.color)
                    .frame(width: 3, height: 26)
                LoopFace(loop: loop, phase: phase, size: 15)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text(loop.displayName)
                            .font(Theme.font(13, .medium))
                            .foregroundStyle(phase == .failed ? Theme.critical : Theme.textPrimary)
                        Spacer(minLength: 6)
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            Text(when(now: context.date))
                                .font(Theme.font(12).monospacedDigit())
                                .foregroundStyle(phase == .running ? Theme.ok : Theme.textSecondary)
                        }
                    }
                    Text(loop.last?.note ?? "No run logged yet")
                        .font(Theme.font(12))
                        .foregroundStyle(Theme.textSecondary)
                }
                .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .frame(height: 36)
        }
    }

    /// "running 4m", "today 07:56", "yesterday".
    private func when(now: Date) -> String {
        if let since = loop.runningSince, loop.isRunning { return "running \(Durations.short(now.timeIntervalSince(since)))" }
        guard let last = loop.last else { return "" }
        let day = TimeText.day(last.day)
        if let date = loop.outboxDate, AgentScanner.day(date) == last.day { return "\(day) \(TimeText.clock(date))" }
        return day
    }
}

/// The loops view: a list (default) or today's timeline, with a compact switch.
struct LoopsCard: View {
    let module: AgentsModule
    @Namespace private var toggle

    var body: some View {
        NotchCard(padding: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button {
                        _ = module.handleBack()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                            Text("Sessions").font(Theme.font(12, .medium))
                        }
                        .foregroundStyle(Theme.textSecondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScale())
                    Spacer()
                    if !module.loops.isEmpty {
                        HStack(spacing: 2) {
                            option("List", selected: !module.loopsAsTimeline) { module.loopsAsTimeline = false }
                            option("Today", selected: module.loopsAsTimeline) { module.loopsAsTimeline = true }
                        }
                    }
                }
                .padding(.horizontal, 4)
                ZStack {
                    if module.loops.isEmpty {
                        LoopsEmpty().transition(.opacity)
                    } else if module.loopsAsTimeline {
                        // More loops than the panel holds scroll; the axis follows the last row.
                        // The axis ends a little early: the scroll view clips, and "24" and a
                        // dot at midnight sit centred on its end.
                        ScrollView(.vertical) {
                            LoopTimelineView(module: module).padding(.trailing, 9)
                        }
                        .scrollIndicators(.never)
                        .transition(.blurSlide(x: 14))
                    } else {
                        // Scrolls inside the card; a soft fade says there is more below.
                        ScrollView(.vertical) {
                            LoopRows(module: module).padding(.bottom, 10)
                        }
                        .scrollIndicators(.never)
                        .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.88),
                                                     .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                        .transition(.blurSlide(x: -14))
                    }
                }
            }
        }
        .animation(Theme.snappy, value: module.loopsAsTimeline)
    }

    private func option(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tick()
            withAnimation(Theme.snappy) { action() }
        } label: {
            Text(title)
                .font(Theme.font(12, selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.white.opacity(0.1))
                            .matchedGeometryEffect(id: "loops.toggle", in: toggle)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
    }
}

/// Today per loop on one time axis: dots for runs (green ok, amber degraded, red failed, grey
/// skipped), hollow rings for runs to come, a dashed ring for a missed one, a "now" line.
private struct LoopTimelineView: View {
    let module: AgentsModule
    private let labelWidth: CGFloat = 150
    /// Where each row's track begins: the label column plus the row's spacing.
    private var trackStart: CGFloat { labelWidth + 8 }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let start = Calendar.current.startOfDay(for: context.date)
            VStack(spacing: 0) {
                ForEach(module.loops) { loop in
                    row(loop, dayStart: start).frame(height: 28)
                }
                hours.padding(.leading, trackStart).padding(.top, 2)
            }
            .overlay(alignment: .topLeading) {
                GeometryReader { proxy in
                    let x = trackStart + (proxy.size.width - trackStart) * fraction(context.date, dayStart: start)
                    Rectangle()
                        .fill(Theme.accent.opacity(0.7))
                        .frame(width: 1, height: CGFloat(module.loops.count) * 28)
                        .offset(x: x)
                }
            }
        }
    }

    private func row(_ loop: AgentSnapshot.LoopStatus, dayStart: Date) -> some View {
        let phase = module.phase(of: loop)
        return Button { module.openLoop(loop.name) } label: {
            HStack(spacing: 8) {
                LoopFace(loop: loop, phase: phase, size: 14).frame(width: 18)
                Text(loop.displayName)
                    .font(Theme.font(12.5, .medium))
                    .foregroundStyle(phase == .failed ? Theme.critical : Theme.textPrimary)
                    .lineLimit(1)
                    .frame(width: labelWidth - 26, alignment: .leading)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                        ForEach(Array(loop.slots.enumerated()), id: \.offset) { _, slot in
                            dot(slot, running: loop.isRunning && slot.status == nil && slot.at <= Date())
                                .position(x: proxy.size.width * fraction(slot.at, dayStart: dayStart), y: proxy.size.height / 2)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .help("\(loop.displayName) · \(phase.word)")
    }

    @ViewBuilder private func dot(_ slot: LoopTimeline.Slot, running: Bool) -> some View {
        if running {
            PulsingDot()
        } else if let status = slot.status {
            Circle().fill(color(status)).frame(width: 7, height: 7)
        } else if slot.missed {
            Circle().strokeBorder(Theme.waiting.opacity(0.8), style: StrokeStyle(lineWidth: 1.2, dash: [2, 2])).frame(width: 8, height: 8)
        } else {
            Circle().strokeBorder(Color.white.opacity(0.4), lineWidth: 1.2).frame(width: 7, height: 7)
        }
    }

    private var hours: some View {
        GeometryReader { proxy in
            ForEach([0, 6, 12, 18, 24], id: \.self) { hour in
                Text(String(format: "%02d", hour))
                    .font(Theme.font(10.5).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                    .position(x: proxy.size.width * CGFloat(hour) / 24, y: 6)
            }
        }
        .frame(height: 12)
    }

    private func color(_ status: LoopRun.Status) -> Color {
        switch status {
        case .ok: Theme.ok
        case .degraded: Theme.waiting
        case .fail: Theme.critical
        default: Theme.textTertiary
        }
    }

    private func fraction(_ date: Date, dayStart: Date) -> CGFloat {
        CGFloat(min(1, max(0, date.timeIntervalSince(dayStart) / 86_400)))
    }
}

/// Everything about one loop: status, last run, its logged runs, what it delivered, next run.
struct LoopDetailCard: View {
    let module: AgentsModule
    let loop: AgentSnapshot.LoopStatus

    var body: some View {
        let phase = module.phase(of: loop)
        NotchCard(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    Button { _ = module.handleBack() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScale())
                    .help("Back (← or esc)")
                    LoopFace(loop: loop, phase: phase, size: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 8) {
                            Text(loop.displayName)
                                .font(Theme.font(15, .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text(phase.word)
                                .font(Theme.font(12, .medium))
                                .foregroundStyle(phase == .done ? Theme.textSecondary : phase.color)
                        }
                        Text(summary)
                            .font(Theme.font(12).monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    if let link = loop.outboxLink {
                        Button("Open result") { NSWorkspace.shared.open(link) }
                            .buttonStyle(PressScale())
                            .font(Theme.font(12, .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    if let url = loop.specURL {
                        Button(Runtime.jobs?.specLinkTitle ?? "Open spec") { NSWorkspace.shared.open(url) }
                            .buttonStyle(PressScale())
                            .font(Theme.font(12, .medium))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

                HStack(alignment: .top, spacing: 14) {
                    // Last logged runs, newest first.
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Log").font(Theme.font(11.5, .medium)).foregroundStyle(Theme.textTertiary)
                        ForEach(Array(loop.history.reversed().enumerated()), id: \.offset) { _, entry in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Circle().fill(statusColor(entry.status)).frame(width: 6, height: 6)
                                Text(TimeText.day(entry.day)).foregroundStyle(Theme.textSecondary).frame(width: 62, alignment: .leading)
                                Text(entry.note.isEmpty ? entry.status.rawValue : entry.note).foregroundStyle(Theme.textBody)
                                    .lineLimit(2)
                            }
                            .font(Theme.font(12))
                        }
                        if loop.history.isEmpty {
                            Text("No run logged yet").font(Theme.font(12)).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .frame(width: 270, alignment: .leading)

                    // What the loop delivered last, as written.
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Last message").font(Theme.font(11.5, .medium)).foregroundStyle(Theme.textTertiary)
                        ScrollView {
                            Text(loop.outbox?.isEmpty == false ? loop.outbox! : "No message in the outbox.")
                                .font(Theme.font(12.5))
                                .foregroundStyle(Theme.textBody)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .scrollIndicators(.never)
                    }
                }
            }
        }
    }

    /// "last run today 07:56 · next 04:30"
    private var summary: String {
        var parts: [String] = []
        if loop.isRunning, let since = loop.runningSince {
            parts.append("running for \(Durations.short(Date().timeIntervalSince(since)))")
        } else if let last = loop.last {
            var text = "last run \(TimeText.day(last.day))"
            if let date = loop.outboxDate, AgentScanner.day(date) == last.day { text += " \(TimeText.clock(date))" }
            parts.append(text)
        }
        if let next = loop.nextRun { parts.append("next \(TimeText.clock(next))") }
        return parts.joined(separator: " · ")
    }

    private func statusColor(_ status: LoopRun.Status) -> Color {
        switch status {
        case .ok: Theme.ok
        case .degraded: Theme.waiting
        case .fail: Theme.critical
        default: Theme.textTertiary
        }
    }

}

/// A thin line that fills and shimmers while a loop runs.
struct ProgressLine: View {
    let progress: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(Theme.ok).frame(width: proxy.size.width * progress)
                    .shimmering(!reduceMotion)
            }
        }
        .animation(.easeOut(duration: 0.4), value: progress)
    }
}

private struct PulsingDot: View {
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().fill(Theme.ok.opacity(0.35)).frame(width: 16, height: 16)
                .scaleEffect(pulse ? 1 : 0.4).opacity(pulse ? 0 : 1)
            Circle().fill(Theme.ok).frame(width: 8, height: 8)
                .shadow(color: Theme.ok.opacity(0.8), radius: 4)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

/// The plan limits in the panel header: one quiet chip per tool ("Claude 62 %"), the same shape
/// for one tool, two or more; a click opens every window with its reset (`LimitsPage`). The
/// ring is in Tara's colour, red from 90 %; the text stays neutral. A tool that hasn't reported
/// for a while (`staleAfter`) keeps its chip, dimmed, after the fresh ones, so the header
/// doesn't jump when one app has been closed for long. Before the bridge is set up: a link to
/// the setup note.
struct PlanBadge: View {
    let module: AgentsModule

    /// Numbers older than this are shown dimmed, with when they were last seen.
    static let staleAfter: TimeInterval = 3 * 3600

    /// Fresh tools first, then the stale ones, each in the order they came.
    static func arranged(_ usages: [AgentUsage], now: Date) -> [AgentUsage] {
        let fresh = usages.filter { now.timeIntervalSince($0.capturedAt) < staleAfter }
        return fresh + usages.filter { now.timeIntervalSince($0.capturedAt) >= staleAfter }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            let usages = Self.arranged(module.usages.map { $0.current(now: now) }, now: now)
            if !usages.isEmpty {
                // Claude without numbers and without the bridge: a link to set it up, while it fits.
                let setUp = !module.statusBridgeInstalled && !usages.contains { $0.provider == ClaudeCodeProvider.id }
                // A real button (keyboard, VoiceOver); the setup link beside it stays its own.
                let chips = { (style: UsagePill.Style) in
                    Button { module.toggleLimits() } label: {
                        HStack(spacing: style == .ring ? 6 : style == .stacked ? 8 : 12) {
                            ForEach(usages, id: \.provider) { usage in
                                UsagePill(usage: usage, style: style, now: now, module: module,
                                          stale: now.timeIntervalSince(usage.capturedAt) >= Self.staleAfter)
                            }
                        }
                        .fixedSize()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScale())
                    .help(Localization.string("Plan limits: click for every window and its reset"))
                }
                HStack(spacing: 10) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { if setUp { claudeSetUp(true) }; chips(usages.count == 1 ? .detailed : .named) }.fixedSize()
                        HStack(spacing: 10) { if setUp { claudeSetUp(false) }; chips(.named) }.fixedSize()
                        chips(.named)
                        chips(.stacked)
                        chips(.percent)
                        chips(.ring)
                    }
                }
                .onAppear { if module.previewShowsLimits, !module.showsLimits { module.toggleLimits() } }
            } else if module.statusBridgeInstalled {
                ViewThatFits(in: .horizontal) {
                    Text("Plan limits after the next reply").fixedSize()
                    Text("Limits soon").fixedSize()
                    Image(systemName: "hourglass")
                }
                .font(Theme.font(12)).foregroundStyle(Theme.textTertiary)
                    .help("Claude Code reports the 5-hour and weekly limits after the first answer in a session (Pro and Max plans).")
            } else {
                Button {
                    if let url = StatusFiles.setupGuide { NSWorkspace.shared.open(url) }
                } label: {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 4) {
                            Text("Set up usage")
                            Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                        }
                        .fixedSize()
                        HStack(spacing: 4) {
                            Text("Usage")
                            Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                        }
                        .fixedSize()
                        Image(systemName: "gauge.with.dots.needle.33percent")
                    }
                    .font(Theme.font(12, .medium))
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(PressScale())
                .help("Show plan limits and context: one line in Claude Code's settings")
            }
        }
    }

    /// "Claude ↗": opens the setup page for Claude's plan limits.
    private func claudeSetUp(_ named: Bool) -> some View {
        Button {
            if let url = StatusFiles.setupGuide { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 4) {
                Text(named ? "Claude limits" : "Claude").fixedSize()
                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
            }
            .font(Theme.font(12, .medium)).foregroundStyle(Theme.accent)
        }
        .buttonStyle(PressScale())
        .help("Show Claude's plan limits: one line in Claude Code's settings")
    }
}

/// Every tool's 5-hour and weekly windows with their resets, in place of the sessions after a
/// click on the header's chips: a compact card per tool side by side (more tools wrap and
/// scroll), a row per window with its share as a number and a bar, when it resets and, when it
/// runs out first, at what time. The bar in Tara's colour like the Dashboard's, red from 90 %.
struct LimitsPage: View {
    let module: AgentsModule

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            let usages = PlanBadge.arranged(module.usages.map { $0.current(now: now) }, now: now)
            NotchCard(padding: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button { _ = module.handleBack() } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                                Text("Sessions").font(Theme.font(12, .medium))
                            }
                            .foregroundStyle(Theme.textSecondary)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressScale())
                        Spacer()
                        Text("Plan limits").font(Theme.font(12, .semibold)).foregroundStyle(Theme.textPrimary)
                    }
                    .padding(.horizontal, 4)
                    ScrollView(.vertical) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 8, alignment: .top)], spacing: 8) {
                            ForEach(usages, id: \.provider) { usage in
                                ToolLimits(usage: usage, now: now, module: module)
                            }
                        }
                    }
                    .scrollIndicators(.never)
                    .scrollEdgeFade(bottom: 10)
                }
            }
        }
    }
}

/// One tool on the limits page: its badge, plan and when the numbers came, then its windows.
private struct ToolLimits: View {
    let usage: AgentUsage
    let now: Date
    let module: AgentsModule

    var body: some View {
        let stale = now.timeIntervalSince(usage.capturedAt) >= PlanBadge.staleAfter
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ToolBadge(provider: usage.provider)
                if let plan = usage.plan {
                    Text(plan.capitalized).font(Theme.font(11)).foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 6)
                Text(String(format: Localization.string(stale ? "Last seen %@" : "Updated %@"), TimeText.clock(usage.capturedAt, from: now)))
                    .font(Theme.font(10.5)).foregroundStyle(Theme.textTertiary)
            }
            .lineLimit(1)
            ForEach([usage.primary, usage.secondary].compactMap { $0 }, id: \.label) { window in
                // Only when it runs out before the reset: "full 15:40".
                LimitRow(window: window, now: now, pace: stale ? nil : module.paceShort(usage.provider, window, now: now))
            }
            .opacity(stale ? 0.55 : 1)
        }
        .padding(10)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// One plan window: "5-hour window · 66 %", a thin bar, "Resets 16:55 · in 2 h 23 m · full 16:40".
private struct LimitRow: View {
    let window: AgentUsage.Window
    let now: Date
    let pace: String?

    var body: some View {
        let used = window.usedPercent
        let critical = QuotaEstimator.level(used / 100) == .critical
        let isWeek = window.label == "week"
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(isWeek ? "Week" : window.label == "5 h" ? "5-hour window" : window.label.isEmpty ? "Window" : window.label)
                    .font(Theme.font(11.5, .medium))
                    .foregroundStyle(Theme.textBody)
                Spacer(minLength: 8)
                Text("\(Int(used.rounded())) %")
                    .font(Theme.font(12.5, .semibold).monospacedDigit())
                    .foregroundStyle(critical ? Theme.critical : Theme.textPrimary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.09))
                    Capsule().fill(critical ? Theme.critical : TaraAccent.current)
                        .frame(width: max(4, proxy.size.width * min(1, used / 100)))
                }
            }
            .frame(height: 4)
            let line = [window.resetsAt.map { resetLine($0, isWeek: isWeek) }, pace].compactMap { $0 }.joined(separator: " · ")
            if !line.isEmpty {
                Text(line)
                    .font(Theme.font(10.5).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "Resets 16:55 · in 2 h 23 m"; the week "Resets Tue 07:44".
    private func resetLine(_ reset: Date, isWeek: Bool) -> String {
        let at = String(format: Localization.string("Resets %@"), TimeText.clock(reset, from: now))
        guard !isWeek, reset > now else { return at }
        return at + " · " + String(format: Localization.string("in %@"), UsageText.short(UsageText.left(until: reset, now: now)))
    }
}

/// The small ring of a plan window in the header: Tara's colour, red from 90 %.
struct LimitRing: View {
    let used: Double
    let level: QuotaEstimator.Level
    var size: CGFloat = 13

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.18), lineWidth: 2.2)
            Circle().trim(from: 0, to: min(1, used / 100))
                .stroke(level == .critical ? Theme.critical : TaraAccent.current, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}

/// One tool's plan limits in the header: ring, name and the share of its fuller window ("Claude
/// 62 %"), or when it runs out ("Claude full 16:40"); both windows and their resets in the
/// tooltip and the popover. Stale numbers dim.
struct UsagePill: View {
    /// `detailed`: also the reset of the fuller window (one tool alone); `named`: ring, name and
    /// value; `stacked`: the value over the tool's name, like a Dashboard number (narrow headers);
    /// `percent`: ring and value; `ring`: the ring alone.
    enum Style { case detailed, named, stacked, percent, ring }
    let usage: AgentUsage
    let style: Style
    let now: Date
    var module: AgentsModule?
    var stale = false

    var body: some View {
        let window = [usage.primary, usage.secondary].compactMap { $0 }.max { $0.usedPercent < $1.usedPercent }
        let used = window?.usedPercent ?? 0
        let level = QuotaEstimator.level(used / 100)
        let percent = "\(Int(used.rounded())) %"
        // The week only says so when it is the fuller window.
        let suffix = window.map { $0.label == "5 h" || $0.label.isEmpty ? "" : " \($0.label)" } ?? ""
        // On pace to run out before a reset: when, instead of how much (the ring keeps the share).
        let pace = stale ? nil : module?.paceShort(of: usage, now: now)
        let reset = window?.resetsAt.map { window?.label == "week" ? UsageText.resetDay($0, now: now, calendar: .current)
                                                                   : UsageText.short(UsageText.left(until: $0, now: now)) }
        HStack(spacing: 5) {
            LimitRing(used: used, level: level)
            if style == .detailed || style == .named {
                Text(AgentsModule.toolLabel(of: usage.provider)).foregroundStyle(Theme.textSecondary)
            }
            switch style {
            case .detailed:
                Text(pace ?? "\(percent)\(suffix)\(reset.map { " · \($0)" } ?? "")")
            case .named:
                Text(pace ?? "\(percent)\(suffix)")
            case .stacked:
                // The value over the tool's name ("3 %" over "Codex"); which window it is, in the popover.
                VStack(alignment: .leading, spacing: -1) {
                    Text(pace ?? percent).font(Theme.font(12, .semibold).monospacedDigit())
                    Text(AgentsModule.toolLabel(of: usage.provider))
                        .font(Theme.font(9.5, .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
            case .percent:
                Text(percent)
            case .ring: EmptyView()
            }
        }
        .font(Theme.font(12, .medium).monospacedDigit())
        .foregroundStyle(level == .critical ? Theme.critical : Theme.textPrimary)
        .opacity(stale ? 0.45 : 1)
        .help(help)
    }

    private var help: String {
        var lines = ["\(usage.displayName)\(usage.plan.map { " (\($0))" } ?? "")"]
        for window in [usage.primary, usage.secondary].compactMap({ $0 }) {
            let name = window.label == "week" ? "Week" : "\(window.label) window"
            let reset = window.resetsAt.map { window.label == "week" ? ", \(UsageText.resetDay($0, now: now, calendar: .current))" : ", \(UsageText.left(until: $0, now: now))" } ?? ""
            lines.append("\(name): \(Int(window.usedPercent.rounded())) % used\(reset)")
            if let pace = module?.forecast(usage.provider, window, now: now) { lines.append("  \(pace)") }
        }
        lines.append(usage.provider == ClaudeCodeProvider.id ? "From Claude Code's status line, \(TimeText.clock(usage.capturedAt, from: now))."
                                                            : "From \(usage.displayName)'s session files, \(TimeText.clock(usage.capturedAt, from: now)).")
        return lines.joined(separator: "\n")
    }
}

/// A thin ring for a session's context window: Tara's colour from 70 %, red from 90 %.
struct ContextRing: View {
    let percentage: Double
    var size: CGFloat = 11

    var body: some View {
        let level = UsageText.contextLevel(percentage)
        let tint: Color = switch level {
        case .calm: Theme.textSecondary
        case .warn: Theme.waiting
        case .critical: Theme.critical
        }
        ZStack {
            Circle().stroke(Color.white.opacity(0.14), lineWidth: 1.6)
            Circle().trim(from: 0, to: min(1, percentage / 100))
                .stroke(tint, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}
