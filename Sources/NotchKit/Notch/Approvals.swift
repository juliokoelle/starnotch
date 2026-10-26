import AppKit
import NotchCore
import Observation
import SwiftUI

/// Permission prompts from Claude Code (through the starnotch-approvals plugin) as a card in the
/// island: one at a time, the rest queued. Nothing is ever allowed without a click.
@MainActor
@Observable
final class ApprovalCenter {
    struct Pending: Identifiable {
        var request: ApprovalRequest
        var reply: @Sendable (ApprovalDecision?) -> Void
        var arrived = Date()
        var id: String { request.id }
    }

    private(set) var queue: [Pending] = []
    var current: Pending? { queue.first }
    /// Shown (and the island opened) when a request arrives.
    @ObservationIgnored var onShow: (() -> Void)?
    @ObservationIgnored var onEmpty: (() -> Void)?
    /// The pending requests changed (their sessions show "waiting for you").
    @ObservationIgnored var onChange: (([ApprovalRequest]) -> Void)?
    @ObservationIgnored private var server: ApprovalServer?
    static let timeout: TimeInterval = 60

    static var socketPath: String { Brand.supportFolder.appending(path: "approvals.sock").path }

    func start() {
        let server = ApprovalServer(path: Self.socketPath, handler: { [weak self] request, reply in
            Task { @MainActor in self?.receive(request, reply: reply) }
        }, onCancel: { [weak self] id in
            Task { @MainActor in self?.remove(id) }
        })
        do {
            try server.start()
            self.server = server
        } catch {
            Log.app.error("Approvals socket: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() { server?.stop() }

    /// Previews: a made-up request with no hook behind it.
    func preview(_ request: ApprovalRequest) {
        receive(request, reply: { _ in })
    }

    private func receive(_ request: ApprovalRequest, reply: @escaping @Sendable (ApprovalDecision?) -> Void) {
        let wasEmpty = queue.isEmpty
        withAnimation(Theme.snappy) { queue.append(Pending(request: request, reply: reply)) }
        onChange?(queue.map(\.request))
        if wasEmpty { show() }
        // Unanswered: Claude Code's own prompt takes over.
        let id = request.id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.timeout))
            self?.expire(id)
        }
    }

    private func show() {
        Haptics.open()
        onShow?()
    }

    func answer(_ decision: ApprovalDecision) {
        guard let pending = queue.first else { return }
        // Codex can't take a session rule: ⌘↵ does nothing there rather than something else.
        if decision == .allowSession, !pending.request.supportsSessionRules { return }
        Haptics.confirm()
        pending.reply(decision)
        advance()
    }

    private func expire(_ id: String) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[index].reply(nil)
        remove(id)
    }

    /// Answered in the terminal, or timed out.
    private func remove(_ id: String) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        if index == 0 { advance() } else { queue.remove(at: index); onChange?(queue.map(\.request)) }
    }

    private func advance() {
        withAnimation(Theme.snappy) { _ = queue.removeFirst() }
        onChange?(queue.map(\.request))
        if queue.isEmpty { onEmpty?() } else { show() }
    }
}

/// "<Session> wants to run …": the request, the session's character waiting, and the three answers.
struct ApprovalCard: View {
    let center: ApprovalCenter
    let pending: ApprovalCenter.Pending
    let agents: AgentsModule?

    private var agent: AgentSnapshot.Agent? {
        guard let id = pending.request.agentID else { return nil }
        return agents?.snapshot.agents.first { $0.id == id }
    }

    private var verb: String {
        switch pending.request.tool {
        case "Bash": "run"
        case "Edit", "MultiEdit", "NotebookEdit": "edit"
        case "Write": "write"
        case "Read": "read"
        case "WebFetch": "open"
        case "WebSearch": "search the web for"
        case "apply_patch": "edit"
        default: "use \(pending.request.tool) on"
        }
    }

    /// A question from an agent through the MCP server (`mcp/`): its client asks, Yes or No.
    private var isQuestion: Bool { pending.request.provider == ApprovalRequest.mcpProvider }

    var body: some View {
        let request = pending.request
        let title = agent?.displayTitle ?? request.cwd.map { ($0 as NSString).lastPathComponent } ?? "A session"
        let headline = isQuestion ? "\(request.tool) asks" : "\(title) wants to \(verb)"
        NotchCard(padding: 14) {
            HStack(alignment: .top, spacing: 14) {
                if let agent, let agents {
                    AvatarView(character: agents.character(of: agent), mood: .yourTurn, height: 64,
                               colorway: agents.colorway(of: agent), emergeOnAppear: false,
                               level: agents.variantLevel(of: agent))
                        .frame(width: 70, height: 70, alignment: .bottom)
                } else {
                    Image(systemName: "hand.raised.fill").font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Theme.waiting).frame(width: 70, height: 70)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text(headline)
                            .font(Theme.font(14, .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        if request.provider != ClaudeCodeProvider.id && !isQuestion { ToolBadge(provider: request.provider) }
                        Spacer(minLength: 6)
                        if center.queue.count > 1 {
                            Text("+\(center.queue.count - 1) waiting").font(Theme.font(11.5)).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    Text(request.summary.isEmpty ? request.tool : request.summary)
                        .font(isQuestion ? Theme.font(13, .medium) : .system(size: 12.5, design: .monospaced))
                        .foregroundStyle(Theme.textBody)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .help(request.detail)
                    HStack(spacing: 8) {
                        button(isQuestion ? "Yes" : "Allow once", key: "↵", style: .primary) { center.answer(.allowOnce) }
                        if request.supportsSessionRules {
                            button("Allow for session", key: "⌘↵", style: .secondary) { center.answer(.allowSession) }
                        }
                        Spacer(minLength: 4)
                        button(isQuestion ? "No" : "Deny", key: "esc", style: .quiet) { center.answer(.deny) }
                    }
                    Text(isQuestion ? "Unanswered, \(request.tool) hears no answer after \(Int(ApprovalCenter.timeout)) s."
                         : "Unanswered, \(request.provider == CodexProvider.id ? "Codex" : "the terminal") asks after \(Int(ApprovalCenter.timeout)) s.")
                        .font(Theme.font(10.5)).foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    private enum Style { case primary, secondary, quiet }

    private func button(_ title: String, key: String, style: Style, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(Theme.font(12.5, .semibold))
                Text(key).font(Theme.font(10.5, .medium)).opacity(0.6)
            }
            .foregroundStyle(style == .primary ? Color.white : style == .secondary ? Theme.accent : Theme.textSecondary)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(style == .primary ? Theme.accent : style == .secondary ? Theme.accent.opacity(0.14) : Color.white.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(PressScale())
    }
}
