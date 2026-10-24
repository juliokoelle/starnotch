import AppKit
import NotchCore
import SwiftUI

extension AgentSnapshot.Subagent {
    var statusWord: String {
        switch status {
        case .running: "running"
        case .done: "done"
        case .failed: "failed"
        case .stopped: "stopped"
        }
    }

    /// Finished within this window still counts as current; older ones are history.
    static let recentWindow: TimeInterval = 2 * 3600

    var isRecent: Bool {
        status == .running || (modified.map { Date().timeIntervalSince($0) < Self.recentWindow } ?? false)
    }

    /// "1 running · 3 done": the running ones and those finished in the last two hours; nil
    /// when there are none (older ones show as "+N earlier").
    static func summary(_ subagents: [AgentSnapshot.Subagent], earlier: Int) -> String? {
        let running = subagents.filter { $0.status == .running }.count
        let done = subagents.filter { $0.status != .running && $0.isRecent }.count
        let parts = [running > 0 ? "\(running) running" : nil,
                     done > 0 ? "\(done) done" : nil].compactMap { $0 }
        return parts.isEmpty ? nil : "Subagents: " + parts.joined(separator: " · ")
    }

    /// Elapsed while running, else how long it took.
    func elapsed(now: Date) -> String? {
        guard let start = progress.startedAt else { return nil }
        let end = status == .running ? now : (progress.lastDate ?? modified ?? now)
        return Durations.short(max(0, end.timeIntervalSince(start)))
    }
}

/// A subagent under its parent: indented, a thin elbow from the parent, the parent's character
/// small, "subagent", its state. Done ones are dimmed with a check, failed ones carry a red dot.
struct SubagentRow: View {
    let module: AgentsModule
    let parent: AgentSnapshot.Agent
    let sub: AgentSnapshot.Subagent
    var last = false
    @State private var hovering = false

    var body: some View {
        Button { module.openSubagent(sub.id, of: parent) } label: {
            HStack(spacing: 6) {
                Connector(last: last).frame(width: 14)
                AvatarView(character: module.character(of: parent), mood: sub.status == .running ? .working : .idle,
                           height: 22, colorway: module.colorway(of: parent), sink: 0.04, emergeOnAppear: false,
                           alive: sub.status == .running, level: module.variantLevel(of: parent))
                    .frame(width: 24, height: 24, alignment: .bottom)
                    .opacity(sub.status == .running ? 1 : 0.55)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 5) {
                        Text(sub.name).font(Theme.font(11.5, .semibold)).foregroundStyle(Theme.textPrimary)
                        Text("subagent").font(Theme.font(10)).foregroundStyle(Theme.textTertiary)
                    }
                    Text(sub.status == .running ? (sub.step ?? "Starting…") : sub.progress.lastText ?? sub.statusWord)
                        .font(Theme.font(11)).foregroundStyle(Theme.textSecondary)
                }
                .lineLimit(1)
                .opacity(sub.status == .running ? 1 : 0.6)
                Spacer(minLength: 4)
                StatusMark(status: sub.status)
                    .padding(.trailing, 8)
            }
            .frame(height: 30)
            .background(Color.white.opacity(hovering ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .onHover { hovering = $0 }
        .help("\(sub.name) · subagent of \(parent.displayTitle) · \(sub.statusWord)")
    }
}

/// The thin elbow line from the parent down to a subagent.
private struct Connector: View {
    let last: Bool

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                let x = proxy.size.width * 0.4
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: last ? proxy.size.height / 2 : proxy.size.height))
                path.move(to: CGPoint(x: x, y: proxy.size.height / 2))
                path.addLine(to: CGPoint(x: proxy.size.width, y: proxy.size.height / 2))
            }
            .stroke(Color.white.opacity(0.16), lineWidth: 1)
        }
    }
}

struct StatusMark: View {
    let status: SubagentProgress.Status

    var body: some View {
        switch status {
        case .running:
            ProgressDots()
        case .done:
            Image(systemName: "checkmark").font(.system(size: 9.5, weight: .bold)).foregroundStyle(Theme.ok.opacity(0.8))
        case .failed:
            Circle().fill(Theme.critical).frame(width: 6, height: 6)
        case .stopped:
            Image(systemName: "pause.fill").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.textTertiary)
        }
    }
}

/// Three dots breathing in sequence: running.
private struct ProgressDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { index in
                    Circle().fill(Theme.accent)
                        .frame(width: 3.5, height: 3.5)
                        .opacity(reduceMotion ? 1 : 0.35 + 0.65 * max(0, sin(t * 4 - Double(index) * 0.9)))
                }
            }
        }
    }
}

/// One subagent in detail: what it was asked, how it's going, its last steps (the current one
/// highlighted), its latest line, and when done the start of its report.
struct SubagentDetailCard: View {
    let module: AgentsModule
    let parent: AgentSnapshot.Agent
    let sub: AgentSnapshot.Subagent

    var body: some View {
        NotchCard(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    Button { _ = module.handleBack() } label: {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary).frame(width: 22, height: 22).contentShape(Rectangle())
                    }
                    .buttonStyle(PressScale())
                    .help("Back (← or esc)")
                    AvatarView(character: module.character(of: parent), mood: sub.status == .running ? .working : .idle,
                               height: 30, colorway: module.colorway(of: parent), emergeOnAppear: false,
                               level: module.variantLevel(of: parent))
                        .frame(width: 34, height: 30, alignment: .bottom)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(sub.name).font(Theme.font(15, .semibold)).foregroundStyle(Theme.textPrimary)
                            Text("subagent").font(Theme.font(11)).foregroundStyle(Theme.textTertiary)
                        }
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            HStack(spacing: 5) {
                                StatusMark(status: sub.status)
                                Text([sub.statusWord, sub.elapsed(now: context.date), "of \(parent.displayTitle)"]
                                    .compactMap { $0 }.joined(separator: " · "))
                            }
                            .font(Theme.font(12).monospacedDigit())
                            .foregroundStyle(sub.status == .failed ? Theme.critical : Theme.textSecondary)
                        }
                    }
                    .lineLimit(1)
                    Spacer(minLength: 6)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(sub.progress.partial ? "≥ " : "")\(sub.progress.toolUses) tool uses").font(Theme.font(11.5).monospacedDigit())
                            .help(sub.progress.partial ? "Counted over the latest part of a long transcript" : "")
                        if sub.progress.outputTokens > 0 {
                            Text("\(QuotaEstimator.tokens(sub.progress.outputTokens)) tokens out").font(Theme.font(11.5).monospacedDigit())
                        }
                    }
                    .foregroundStyle(Theme.textTertiary)
                }
                if let task = sub.progress.task {
                    Text(task).font(Theme.font(12)).foregroundStyle(Theme.textSecondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 32)
                }
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Last steps").font(Theme.font(11.5, .medium)).foregroundStyle(Theme.textTertiary)
                        let steps = sub.progress.steps.filter { $0.kind != .message }.suffix(4)
                        if steps.isEmpty { Text("Nothing recorded yet").font(Theme.font(12)).foregroundStyle(Theme.textSecondary) }
                        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                            let current = sub.status == .running && index == steps.count - 1
                            HStack(spacing: 6) {
                                Circle().fill(current ? Theme.accent : Color.white.opacity(0.18)).frame(width: 5, height: 5)
                                Text(step.text).font(Theme.font(12, current ? .semibold : .regular))
                                    .foregroundStyle(current ? Theme.textPrimary : Theme.textBody)
                            }
                            .lineLimit(1)
                        }
                    }
                    .frame(width: 270, alignment: .leading)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(sub.status == .done ? "Report" : "Latest").font(Theme.font(11.5, .medium)).foregroundStyle(Theme.textTertiary)
                        Text(sub.status == .done ? sub.progress.report.map { SubagentProgress.excerpt($0) } ?? "Done."
                                                 : sub.progress.lastText ?? "No output yet.")
                            .font(Theme.font(12.5)).foregroundStyle(Theme.textBody)
                            .lineLimit(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

/// The parent's subagents inside its detail card: status and current step, each clickable.
struct SubagentList: View {
    let module: AgentsModule
    let parent: AgentSnapshot.Agent

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("Subagents").font(Theme.font(11.5, .medium)).foregroundStyle(Theme.textTertiary)
                if let summary = AgentSnapshot.Subagent.summary(parent.subagents, earlier: parent.earlierSubagents) {
                    Text(summary.replacingOccurrences(of: "Subagents: ", with: "")).font(Theme.font(11)).foregroundStyle(Theme.textTertiary)
                }
            }
            ForEach(Array(parent.subagents.enumerated()), id: \.element.id) { index, sub in
                SubagentRow(module: module, parent: parent, sub: sub, last: index == parent.subagents.count - 1)
            }
            if parent.earlierSubagents > 0 {
                Text("+\(parent.earlierSubagents) earlier").font(Theme.font(11)).foregroundStyle(Theme.textTertiary).padding(.leading, 20)
            }
        }
    }
}
