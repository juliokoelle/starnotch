import AppKit
import NotchCore
import Observation
import SwiftUI

/// One queue of everything that needs the user across tools: permission prompts (Claude Code,
/// Codex), questions (MCP ask), finished turns and failed loops. It reads the approvals center
/// and the agents module and answers through them; it keeps only what the user set aside.
@MainActor
@Observable
final class AgentsInbox {
    enum Source {
        case approval(ApprovalCenter.Pending)
        case done(AgentSnapshot.Agent, line: String)
        case loop(AgentSnapshot.LoopStatus)
    }

    struct Item: Identifiable {
        var entry: InboxEntry
        var source: Source
        var id: String { entry.id }
    }

    /// What the controller does after a key: stay on the inbox, close the island (the user went
    /// to a terminal or a file), or open a module's panel.
    enum Outcome { case stay, leave, show(ModuleKind) }

    let approvals: ApprovalCenter
    let agents: AgentsModule
    private(set) var state = InboxQueue()

    init(approvals: ApprovalCenter, agents: AgentsModule) {
        self.approvals = approvals
        self.agents = agents
    }

    // MARK: Items

    /// Everything that needs the user now, unordered.
    private var all: [Item] {
        var items: [Item] = approvals.queue.map { pending in
            let kind: InboxEntry.Kind = pending.request.provider == ApprovalRequest.mcpProvider ? .question : .approval
            return Item(entry: InboxEntry(id: "approval:\(pending.id)", kind: kind, at: pending.arrived), source: .approval(pending))
        }
        let now = Date()
        for agent in agents.snapshot.agents {
            // Done with a turn and the user's move: not busy, not blocked on a prompt (that one is
            // in the list already), within the "your turn" window, with something said.
            guard !agent.isBusy, agent.needsYou == nil, let since = agent.since,
                  now.timeIntervalSince(since) < AgentsModule.waitingWindow, let line = Self.lastLine(of: agent) else { continue }
            items.append(Item(entry: InboxEntry(id: "done:\(agent.id)@\(Int(since.timeIntervalSince1970))", kind: .done, at: since),
                              source: .done(agent, line: line)))
        }
        for loop in agents.failedLoops {
            let at = loop.outboxDate ?? loop.slots.last(where: { $0.status == .fail })?.at ?? now
            items.append(Item(entry: InboxEntry(id: "loop:\(loop.name)@\(loop.last?.day ?? "")#\(loop.history.count)", kind: .failedLoop, at: at),
                              source: .loop(loop)))
        }
        return items
    }

    /// The last thing the session said, first line.
    static func lastLine(of agent: AgentSnapshot.Agent) -> String? {
        let text = agent.lastMessage ?? agent.steps.last { $0.kind == .message }?.text
        return text?.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }

    /// This round's queue, in order.
    var queue: [Item] {
        let items = all
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return state.queue(items.map(\.entry)).compactMap { byID[$0.id] }
    }

    var current: Item? { queue.first }

    /// The number in the ear: everything pending, skipped this round or not.
    var count: Int { state.count(all.map(\.entry)) }

    // MARK: Keys

    /// The inbox opens: last round's skipped prompts are back.
    func startRound() {
        state.forget(keeping: all.map(\.entry))
        state.startRound()
    }

    /// Esc: on to the next. A prompt stays pending (its agent still waits); a notice is done.
    func skip() {
        guard let item = current else { return }
        Haptics.tick()
        state.skip(item.entry)
    }

    /// ↵: allow a prompt, say yes to a question, open a finished session or a failed loop's log.
    func primary() -> Outcome {
        guard let item = current else { return .stay }
        switch item.source {
        case .approval(let pending):
            // A question with answers wants one picked (1–4) or typed; ↵ alone does nothing.
            if pending.request.asksForAnswer { return .stay }
            approvals.answer(.allowOnce, to: pending.id)
            return .stay
        case .done(let agent, _):
            state.dismiss(item.id)
            agents.jump(to: agent)
            return .leave
        case .loop(let loop):
            state.dismiss(item.id)
            if let url = loop.outboxLink ?? Runtime.jobs?.logURL {
                NSWorkspace.shared.open(url)
                return .leave
            }
            agents.openLoop(loop.name)
            return .show(.agents)
        }
    }

    /// ⌘↵: the session behind the item (its terminal or app); a loop opens in the Agents panel.
    func openSession() -> Outcome {
        guard let item = current else { return .stay }
        switch item.source {
        case .approval(let pending):
            guard let agent = agent(of: pending.request) else {
                if let cwd = pending.request.cwd { NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
                    return .leave }
                return .stay
            }
            agents.jump(to: agent)
            return .leave
        case .done(let agent, _):
            state.dismiss(item.id)
            agents.jump(to: agent)
            return .leave
        case .loop(let loop):
            state.dismiss(item.id)
            agents.openLoop(loop.name)
            return .show(.agents)
        }
    }

    func agent(of request: ApprovalRequest) -> AgentSnapshot.Agent? {
        guard let id = request.agentID else { return nil }
        return agents.snapshot.agents.first { $0.id == id }
    }

    /// The card's height in the island.
    var bodyHeight: CGFloat {
        let more: CGFloat = queue.count > 1 ? InboxView.nextLineHeight : 0
        switch current?.source {
        case .approval(let pending)?: return (pending.request.asksForAnswer ? 196 : 150) + more
        case .done?, .loop?: return InboxView.noticeHeight + more
        case nil: return InboxView.emptyHeight
        }
    }
}

// MARK: - View

struct InboxView: View {
    let inbox: AgentsInbox
    let notch: CGSize
    let onKey: (_ primary: Bool) -> Void
    var onEmpty: () -> Void = {}

    static let noticeHeight: CGFloat = 118
    static let nextLineHeight: CGFloat = 26
    static let emptyHeight: CGFloat = 60

    var body: some View {
        let queue = inbox.queue
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text("Inbox").font(Theme.font(12, .semibold)).foregroundStyle(Theme.textSecondary)
                    if inbox.count > 0 {
                        Text("\(inbox.count)").font(Theme.font(12).monospacedDigit()).foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(.leading, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: notch.width)
                hints(queue.first)
                    .padding(.trailing, 14)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(height: notch.height)

            VStack(spacing: 0) {
                if let item = queue.first {
                    card(item)
                        .id(item.id)
                        .transition(.blurSlide(y: -8))
                    if queue.count > 1 { next(Array(queue.dropFirst())) }
                } else {
                    empty.transition(.blurSlide(y: -6))
                }
            }
            .padding(.horizontal, NotchLayout.sideInset)
            .padding(.top, NotchLayout.bodyTop)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .onChange(of: queue.isEmpty) { _, empty in if empty { onEmpty() } }
    }

    /// The keys for the item in front.
    private func hints(_ item: AgentsInbox.Item?) -> some View {
        var parts: [String] = []
        switch item?.source {
        case .approval(let pending)?:
            let request = pending.request
            if request.provider == ApprovalRequest.mcpProvider {
                if !request.options.isEmpty { parts.append(Localization.string("1–4 answer")) }
                else if !request.freeText { parts.append(Localization.string("↵ yes")) }
            } else {
                parts.append(Localization.string("↵ allow"))
            }
            if inbox.agent(of: request) != nil || request.cwd != nil { parts.append(Localization.string("⌘↵ open")) }
            parts.append(Localization.string("esc next"))
        case .done?:
            parts += [Localization.string("↵ open"), Localization.string("esc next")]
        case .loop?:
            parts += [Localization.string("↵ open"), Localization.string("⌘↵ show"), Localization.string("esc next")]
        case nil:
            parts.append("esc")
        }
        return Text(parts.joined(separator: "  "))
            .font(Theme.font(11.5))
            .foregroundStyle(Theme.textTertiary)
            .lineLimit(1)
    }

    @ViewBuilder private func card(_ item: AgentsInbox.Item) -> some View {
        switch item.source {
        case .approval(let pending):
            // The same card as a prompt that opens the island, with the inbox's keys.
            ApprovalCard(center: inbox.approvals, pending: pending, agents: inbox.agents, inInbox: true)
                .frame(height: pending.request.asksForAnswer ? 196 : 150)
        case .done(let agent, let line):
            notice(title: Localization.string("%@ is done").replacingOccurrences(of: "%@", with: agent.displayTitle),
                   detail: line, since: agent.since, provider: agent.provider,
                   primary: "Open session", figure: AnyView(
                    AvatarView(character: inbox.agents.character(of: agent), mood: .yourTurn, height: 60,
                               colorway: inbox.agents.colorway(of: agent), emergeOnAppear: false,
                               level: inbox.agents.variantLevel(of: agent))
                        .frame(width: 64, height: 64, alignment: .bottom)))
        case .loop(let loop):
            notice(title: Localization.string("%@ failed").replacingOccurrences(of: "%@", with: loop.displayName),
                   detail: loop.last?.note.nilIfBlank ?? Localization.string("No note"), since: loop.outboxDate, provider: nil,
                   primary: loop.outboxLink != nil ? "Open result" : Runtime.jobs?.logURL != nil ? "Open the log" : "Show loop",
                   figure: AnyView(AgentFace(color: AgentsModule.loopColor, mood: .failed, size: 34).frame(width: 64, height: 64)))
        }
    }

    private func notice(title: String, detail: String, since: Date?, provider: String?, primary: String, figure: AnyView) -> some View {
        NotchCard(padding: 14) {
            HStack(alignment: .top, spacing: 14) {
                figure
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text(title).font(Theme.font(14, .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        if let provider, inbox.agents.showsToolBadges { ToolBadge(provider: provider) }
                        Spacer(minLength: 6)
                        if let since {
                            Text(Durations.short(Date().timeIntervalSince(since)))
                                .font(Theme.font(11.5).monospacedDigit()).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    Text(detail)
                        .font(Theme.font(13))
                        .foregroundStyle(Theme.textBody)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .help(detail)
                    HStack(spacing: 8) {
                        button(primary, key: "↵", primary: true) { onKey(true) }
                        Spacer(minLength: 4)
                        button("Skip", key: "esc", primary: false) { inbox.skip() }
                    }
                }
            }
        }
        .frame(height: Self.noticeHeight)
    }

    private func button(_ title: String, key: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(LocalizedStringKey(title)).font(Theme.font(12.5, .semibold))
                Text(key).font(Theme.font(10.5, .medium)).opacity(0.6)
            }
            .foregroundStyle(primary ? Color.white : Theme.textSecondary)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(primary ? Theme.accent : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(PressScale())
    }

    /// What follows, in one quiet line.
    private func next(_ rest: [AgentsInbox.Item]) -> some View {
        let names = rest.prefix(3).map(label)
        let more = rest.count > 3 ? " · +\(rest.count - 3)" : ""
        return HStack(spacing: 6) {
            Text("Then").foregroundStyle(Theme.textTertiary)
            Text(names.joined(separator: " · ") + more).foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
        }
        .font(Theme.font(11.5))
        .lineLimit(1)
        .padding(.horizontal, 6)
        .frame(height: Self.nextLineHeight)
    }

    private func label(_ item: AgentsInbox.Item) -> String {
        switch item.source {
        case .approval(let pending):
            let request = pending.request
            if request.provider == ApprovalRequest.mcpProvider {
                return Localization.string("%@ asks").replacingOccurrences(of: "%@", with: request.tool)
            }
            let title = inbox.agent(of: request)?.displayTitle ?? request.cwd.map { ($0 as NSString).lastPathComponent } ?? request.tool
            return Localization.string("%@ waits").replacingOccurrences(of: "%@", with: title)
        case .done(let agent, _): return Localization.string("%@ is done").replacingOccurrences(of: "%@", with: agent.displayTitle)
        case .loop(let loop): return Localization.string("%@ failed").replacingOccurrences(of: "%@", with: loop.displayName)
        }
    }

    private var empty: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.ok)
                .frame(width: 30, height: 30)
                .background(Theme.ok.opacity(0.16), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("Nothing needs you").font(Theme.font(14, .semibold)).foregroundStyle(Theme.textPrimary)
                Text("Prompts, questions and finished turns land here").font(Theme.font(12)).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: Self.emptyHeight)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private extension String {
    var nilIfBlank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
