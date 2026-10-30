import AppKit
import NotchCore
import SwiftUI

/// One session in detail: title, project and branch, status, last steps, last message,
/// subagents, and a small jump to the session itself.
struct SessionDetailCard: View {
    let module: AgentsModule
    let agent: AgentSnapshot.Agent

    var body: some View {
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
                    AvatarView(character: module.character(of: agent), mood: module.avatarMood(of: agent), height: 34,
                               colorway: module.colorway(of: agent), emergeOnAppear: false,
                               level: module.variantLevel(of: agent))
                        .frame(width: 40, height: 34, alignment: .bottom)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(agent.displayTitle)
                            .font(Theme.font(15, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            Text(module.secondary(for: agent, now: context.date))
                                .font(Theme.font(12).monospacedDigit())
                                .foregroundStyle(Theme.textSecondary)
                        }
                        if let label = contextText {
                            HStack(spacing: 5) {
                                if let pct = module.contextPercentage(of: agent) { ContextRing(percentage: pct, size: 10) }
                                Text(label).font(Theme.font(12).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                    .lineLimit(1)
                    Spacer()
                    Button { module.jump(to: agent) } label: {
                        HStack(spacing: 4) {
                            Text("Open session")
                            Image(systemName: "arrow.up.right").font(.system(size: 9.5, weight: .semibold))
                        }
                        .font(Theme.font(12, .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(PressScale())
                    .help(jumpHelp)
                }

                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Last steps").font(Theme.font(11.5, .medium)).foregroundStyle(Theme.textTertiary)
                        if agent.steps.isEmpty {
                            Text("Nothing recorded yet").font(Theme.font(12)).foregroundStyle(Theme.textSecondary)
                        }
                        ForEach(Array(agent.steps.suffix(4).enumerated()), id: \.offset) { _, step in
                            Text(step.text)
                                .font(Theme.font(12))
                                .foregroundStyle(Theme.textBody)
                                .lineLimit(1)
                        }

                    }
                    .frame(width: 270, alignment: .leading)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Last message").font(Theme.font(11.5, .medium)).foregroundStyle(Theme.textTertiary)
                        Text(agent.lastMessage ?? "No message yet.")
                            .font(Theme.font(12.5))
                            .foregroundStyle(Theme.textBody)
                            .lineLimit(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if !agent.subagents.isEmpty {
                    SubagentList(module: module, parent: agent)
                }
            }
        }
    }

    /// "Context 76 % of 200k" or "Context 143k tokens".
    private var contextText: String? {
        let status = module.statuses[agent.id]
        if let pct = module.contextPercentage(of: agent) {
            let window = status?.contextWindowSize.map { " of \(QuotaEstimator.tokens($0))" } ?? ""
            return "Context \(Int(pct.rounded())) %\(window)"
        }
        return agent.contextTokens.map { "Context \(QuotaEstimator.tokens($0)) tokens" }
    }

    private var jumpHelp: String {
        if agent.remoteURL != nil, agent.pid == nil { return "Opens the session on claude.ai (Remote Control)" }
        if agent.remoteURL != nil { return "Opens the session in the Claude app; with ⌥ on claude.ai (Remote Control)" }
        if agent.pid != nil { return "Brings the terminal or app running it to the front" }
        return "Opens the Claude app"
    }
}
