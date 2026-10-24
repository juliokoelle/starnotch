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
                        LoopTimelineView(module: module).transition(.blurSlide(x: 14))
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

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let start = Calendar.current.startOfDay(for: context.date)
            VStack(spacing: 0) {
                ForEach(module.loops) { loop in
                    row(loop, dayStart: start).frame(height: 28)
                }
                hours.padding(.leading, labelWidth).padding(.top, 2)
            }
            .overlay(alignment: .topLeading) {
                GeometryReader { proxy in
                    let x = labelWidth + (proxy.size.width - labelWidth) * fraction(context.date, dayStart: start)
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

/// The plan limits in the panel header, as Claude Code's status line reports them:
/// "5 h 62 % · 2 h 14 m left", the week in the tooltip. Neutral below 80 %, amber from 80 %,
/// red from 90 %. Before the bridge is set up: a link to the setup note.
struct PlanBadge: View {
    let module: AgentsModule
    @State private var showsLimits = false
    @State private var lockToken: Int?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let usages = module.usages.map { $0.current(now: context.date) }
            if usages.contains(where: { $0.provider != ClaudeCodeProvider.id }) {
                // Several tools side by side; Claude without numbers says how to get them.
                let missing = !usages.contains { $0.provider == ClaudeCodeProvider.id }
                let pills = { (style: UsagePill.Style) in
                    HStack(spacing: style == .named ? 10 : 6) {
                        ForEach(usages, id: \.provider) { UsagePill(usage: $0, style: style, now: context.date, module: module) }
                    }
                    .fixedSize()
                }
                // Claude's hint shortens first; the numbers go last.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { if missing { claudeMissing("set up limits") }; limitsButton(pills(.named), usages: usages, now: context.date) }.fixedSize()
                    HStack(spacing: 10) { if missing { claudeMissing("set up") }; limitsButton(pills(.named), usages: usages, now: context.date) }.fixedSize()
                    HStack(spacing: 8) { if missing { claudeMissing(nil) }; limitsButton(pills(.named), usages: usages, now: context.date) }.fixedSize()
                    HStack(spacing: 8) { if missing { claudeMissing(nil) }; limitsButton(pills(.short), usages: usages, now: context.date) }.fixedSize()
                    HStack(spacing: 8) { if missing { claudeMissing(nil) }; limitsButton(pills(.ring), usages: usages, now: context.date) }.fixedSize()
                }
            } else if let plan = module.plan, let five = plan.fiveHour {
                let level = QuotaEstimator.level(five.usedPercentage / 100)
                let tint: Color = switch level {
                case .calm: Theme.textSecondary
                case .warn: Theme.waiting
                case .critical: Theme.critical
                }
                let reset = five.resetsAt.map { UsageText.left(until: $0, now: context.date) }
                let percent = "\(Int(five.usedPercentage.rounded())) %"
                let ring = ZStack {
                    Circle().stroke(Color.white.opacity(0.14), lineWidth: 2)
                    Circle().trim(from: 0, to: min(1, five.usedPercentage / 100))
                        .stroke(level == .calm ? Theme.textBody : tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 12, height: 12)
                // "5 h 53 % · 53 m left", then "53 % · 53 m", then the ring; all of it in the tooltip.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { ring; Text("5 h \(percent)\(reset.map { " · \($0)" } ?? "")") }.fixedSize()
                    HStack(spacing: 6) { ring; Text("\(percent)\(reset.map { " · \(UsageText.short($0))" } ?? "")") }.fixedSize()
                    ring
                }
                .font(Theme.font(12, .medium).monospacedDigit())
                .foregroundStyle(tint)
                .help(help(plan, now: context.date))
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

    /// The tools' numbers; a click shows every window in a popover.
    private func limitsButton(_ pills: some View, usages: [AgentUsage], now: Date) -> some View {
        Button { setShowsLimits(!showsLimits) } label: { pills.contentShape(Rectangle()) }
            .buttonStyle(PressScale())
            .popover(isPresented: Binding(get: { showsLimits }, set: { setShowsLimits($0) }), arrowEdge: .bottom) {
                LimitsPopover(usages: usages, now: now, module: module)
            }
    }

    /// "Claude: set up limits" (opens the setup page), or a wait for the first numbers.
    /// `text` nil: the pill and the arrow only.
    @ViewBuilder private func claudeMissing(_ text: String?) -> some View {
        if module.statusBridgeInstalled {
            HStack(spacing: 5) {
                ToolBadge(provider: ClaudeCodeProvider.id)
                Text(text == nil ? "…" : "after next reply").fixedSize()
            }
            .font(Theme.font(12)).foregroundStyle(Theme.textTertiary)
            .help("Claude Code reports its 5-hour and weekly limits after the first answer in a session.")
        } else {
            Button {
                if let url = StatusFiles.setupGuide { NSWorkspace.shared.open(url) }
            } label: {
                HStack(spacing: 5) {
                    ToolBadge(provider: ClaudeCodeProvider.id)
                    if let text { Text(text).fixedSize() }
                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                }
                .font(Theme.font(12, .medium)).foregroundStyle(Theme.accent)
            }
            .buttonStyle(PressScale())
            .help("Show Claude's plan limits: one line in Claude Code's settings")
        }
    }

    /// The popover holds the island open while it shows.
    private func setShowsLimits(_ show: Bool) {
        showsLimits = show
        if show, lockToken == nil {
            lockToken = IslandLock.shared.acquire("limits") { setShowsLimits(false) }
        } else if !show, let token = lockToken {
            lockToken = nil
            IslandLock.shared.release(token)
        }
    }

    private func help(_ plan: StatusSnapshot, now: Date) -> String {
        var lines: [String] = []
        if let five = plan.fiveHour {
            lines.append("5-hour window: \(Int(five.usedPercentage.rounded())) % used\(five.resetsAt.map { ", \(UsageText.left(until: $0, now: now))" } ?? "")")
        }
        if let week = plan.sevenDay {
            lines.append("Week: \(Int(week.usedPercentage.rounded())) % used\(week.resetsAt.map { ", \(UsageText.resetDay($0, now: now, calendar: .current))" } ?? "")")
        }
        if let five = plan.fiveHour, let pace = module.forecast(ClaudeCodeProvider.id, .init(usedPercent: five.usedPercentage, minutes: 300, resetsAt: five.resetsAt), now: now) {
            lines.append(pace)
        }
        lines.append("From Claude Code's status line, \(TimeText.clock(plan.capturedAt)).")
        return lines.joined(separator: "\n")
    }
}

/// Every tool's 5-hour and weekly windows with their resets, from a click on the header.
private struct LimitsPopover: View {
    let usages: [AgentUsage]
    let now: Date
    let module: AgentsModule

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(usages, id: \.provider) { usage in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        ToolBadge(provider: usage.provider)
                        if let plan = usage.plan { Text(plan).font(Theme.font(11)).foregroundStyle(.secondary) }
                    }
                    ForEach([usage.primary, usage.secondary].compactMap { $0 }, id: \.label) { window in
                        HStack {
                            Text(window.label == "week" ? "Week" : window.label.isEmpty ? "Window" : window.label)
                                .frame(width: 44, alignment: .leading)
                            Text("\(Int(window.usedPercent.rounded())) %").monospacedDigit().frame(width: 44, alignment: .trailing)
                            if let reset = window.resetsAt {
                                Text(window.label == "week" ? UsageText.resetDay(reset, now: now, calendar: .current)
                                                            : UsageText.left(until: reset, now: now))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(Theme.font(12))
                        if let pace = module.forecast(usage.provider, window, now: now) {
                            Text(pace).font(Theme.font(11)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(minWidth: 220, alignment: .leading)
    }
}

/// One tool's plan limits in the header: ring and percentage of its fuller window, both windows
/// and their resets in the tooltip.
struct UsagePill: View {
    /// `short`: the pill and the percentage without the window's name.
    enum Style { case named, short, ring }
    let usage: AgentUsage
    let style: Style
    let now: Date
    var module: AgentsModule?

    var body: some View {
        let window = [usage.primary, usage.secondary].compactMap { $0 }.max { $0.usedPercent < $1.usedPercent }
        let used = window?.usedPercent ?? 0
        let level = QuotaEstimator.level(used / 100)
        let tint: Color = switch level {
        case .calm: Theme.textSecondary
        case .warn: Theme.waiting
        case .critical: Theme.critical
        }
        let ring = ZStack {
            Circle().stroke(Color.white.opacity(0.14), lineWidth: 2)
            Circle().trim(from: 0, to: min(1, used / 100))
                .stroke(level == .calm ? Theme.textBody : tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 12, height: 12)
        let percent = "\(Int(used.rounded())) %"
        // The week only says so when it is the fuller window.
        let suffix = window.map { $0.label == "5 h" || $0.label.isEmpty ? "" : " \($0.label)" } ?? ""
        HStack(spacing: 5) {
            ring
            switch style {
            case .named:
                ToolBadge(provider: usage.provider)
                Text("\(percent)\(suffix)")
            case .short:
                ToolBadge(provider: usage.provider)
                Text(percent)
            case .ring: EmptyView()
            }
        }
        .font(Theme.font(12, .medium).monospacedDigit())
        .foregroundStyle(tint)
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
        lines.append(usage.provider == ClaudeCodeProvider.id ? "From Claude Code's status line, \(TimeText.clock(usage.capturedAt))."
                                                            : "From \(usage.displayName)'s session files, \(TimeText.clock(usage.capturedAt)).")
        return lines.joined(separator: "\n")
    }
}

/// A thin ring for a session's context window: amber from 70 %, red from 90 %.
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
