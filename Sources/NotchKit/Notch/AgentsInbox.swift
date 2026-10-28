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
        /// Blocked where no prompt of ours can answer (the Claude app): only its window can.
        case blocked(AgentSnapshot.Agent, reason: String)
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
        let prompted = Set(approvals.queue.compactMap(\.request.agentID))
        for agent in agents.snapshot.agents {
            // Blocked with no prompt of ours to answer: the Claude app asks in its own window.
            // A block that came from a prompt starts with the approval prefix, also in the moment
            // after the prompt was answered and before the agents caught up.
            if let reason = agent.needsYou, !prompted.contains(agent.id), !reason.hasPrefix(AgentEvent.approvalPrefix) {
                let at = agent.since ?? .distantPast
                items.append(Item(entry: InboxEntry(id: "blocked:\(agent.id)@\(Int(at.timeIntervalSince1970))", kind: .blocked, at: at),
                                  source: .blocked(agent, reason: reason)))
                continue
            }
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

    /// The card on screen. It stays in front until the user moves on or it goes away.
    var current: Item? { queue.first }

    /// The number in the ear: everything pending, skipped this round or not.
    var count: Int { state.count(all.map(\.entry)) }

    /// Pins the front, so an arrival queues behind the card on screen.
    func settle() {
        state.settle(all.map(\.entry), now: Date())
    }

    // MARK: Keys

    /// The inbox opens: last round's skipped prompts are back.
    func startRound() {
        state.forget(keeping: all.map(\.entry))
        state.startRound()
        settle()
    }

    /// What a key or a button acts on: the card on screen (`id`, when a card's own button asks),
    /// and nothing in the moment after the front changed by itself.
    private func target(_ id: String?) -> Item? {
        settle()
        guard let item = current, id == nil || id == item.id, state.accepts(now: Date()) else { return nil }
        return item
    }

    /// Esc: on to the next. A prompt stays pending (its agent still waits); a notice is done.
    func skip(_ id: String? = nil) {
        guard let item = target(id) else { return }
        Haptics.tick()
        state.skip(item.entry)
        settle()
    }

    /// ↵: allow a prompt, say yes to a question, open a finished session or a failed loop's log.
    func primary(_ id: String? = nil) -> Outcome {
        guard let item = target(id) else { return .stay }
        defer { settle() }
        switch item.source {
        case .approval(let pending):
            // A question with answers wants one picked (1–4) or typed; ↵ alone does nothing.
            if pending.request.asksForAnswer { return .stay }
            state.dismiss(item.id)
            approvals.answer(.allowOnce, to: pending.id)
            return .stay
        case .blocked(let agent, _):
            // Still blocked when the inbox opens next: it's back then.
            agents.jump(to: agent)
            return .leave
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
    func openSession(_ id: String? = nil) -> Outcome {
        guard let item = target(id) else { return .stay }
        defer { settle() }
        switch item.source {
        case .approval(let pending):
            guard let agent = agent(of: pending.request) else {
                if let cwd = pending.request.cwd { NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
                    return .leave }
                return .stay
            }
            agents.jump(to: agent)
            return .leave
        case .blocked(let agent, _):
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
        case .approval(let pending)?: return InboxView.height(of: pending.request) + more
        case .done?, .loop?, .blocked?: return InboxView.noticeHeight + more
        case nil: return InboxView.emptyHeight
        }
    }
}

// MARK: - View

struct InboxView: View {
    let inbox: AgentsInbox
    let notch: CGSize
    /// A card's own button: ↵ (`primary`) or ⌘↵, for the item it shows.
    let onKey: (_ primary: Bool, _ id: String) -> Void
    var onEmpty: () -> Void = {}

    static let noticeHeight: CGFloat = 118
    static let nextLineHeight: CGFloat = 26
    static let emptyHeight: CGFloat = 60

    /// A prompt's card: buttons, the options of a question, or options and a field to type.
    static func height(of request: ApprovalRequest) -> CGFloat {
        request.freeText ? 196 : request.asksForAnswer ? 172 : 150
    }

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

            // Worked through by keyboard many times a day: the next card is simply there.
            VStack(spacing: 0) {
                if let item = queue.first {
                    card(item)
                        .id(item.id)
                    if queue.count > 1 { next(Array(queue.dropFirst())) }
                } else if inbox.count > 0 {
                    allSkipped(inbox.count)
                } else {
                    empty
                }
            }
            .padding(.horizontal, NotchLayout.sideInset)
            .padding(.top, NotchLayout.bodyTop)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .onChange(of: queue.map(\.id), initial: true) { inbox.settle() }
        .onChange(of: queue.isEmpty) { _, empty in if empty { onEmpty() } }
    }

    /// The keys for the item in front that no button on its card shows (a button shows its own).
    private func hints(_ item: AgentsInbox.Item?) -> some View {
        var parts: [String] = []
        switch item?.source {
        case .approval(let pending)?:
            let request = pending.request
            if inbox.agent(of: request) != nil || request.cwd != nil { parts.append(Localization.string("⌘↵ open")) }
            parts.append(Localization.string("esc next"))
        case .loop?:
            parts.append(Localization.string("⌘↵ show"))
        case .done?, .blocked?:
            break
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
                .frame(height: Self.height(of: pending.request))
        case .blocked(let agent, let reason):
            notice(item, title: Localization.string("%@ waits").replacingOccurrences(of: "%@", with: agent.displayTitle),
                   detail: reason, since: agent.since, provider: agent.provider,
                   primary: "Open session", secondary: "Skip", figure: AnyView(
                    AvatarView(character: inbox.agents.character(of: agent), mood: .yourTurn, height: 60,
                               colorway: inbox.agents.colorway(of: agent), emergeOnAppear: false,
                               level: inbox.agents.variantLevel(of: agent))
                        .frame(width: 64, height: 64, alignment: .bottom)))
        case .done(let agent, let line):
            notice(item, title: Localization.string("%@ is done").replacingOccurrences(of: "%@", with: agent.displayTitle),
                   detail: line, since: agent.since, provider: agent.provider,
                   primary: "Open session", secondary: "Dismiss", figure: AnyView(
                    AvatarView(character: inbox.agents.character(of: agent), mood: .yourTurn, height: 60,
                               colorway: inbox.agents.colorway(of: agent), emergeOnAppear: false,
                               level: inbox.agents.variantLevel(of: agent))
                        .frame(width: 64, height: 64, alignment: .bottom)))
        case .loop(let loop):
            notice(item, title: Localization.string("%@ failed").replacingOccurrences(of: "%@", with: loop.displayName),
                   detail: loop.last?.note.nilIfBlank ?? Localization.string("No note"), since: loop.outboxDate, provider: nil,
                   primary: loop.outboxLink != nil ? "Open result" : Runtime.jobs?.logURL != nil ? "Open the log" : "Show loop",
                   secondary: "Dismiss", figure: AnyView(AgentFace(color: AgentsModule.loopColor, mood: .failed, size: 34).frame(width: 64, height: 64)))
        }
    }

    /// A finished turn, a failed loop or a blocked session: `secondary` is esc (Dismiss for a
    /// notice, which is gone then; Skip for a blocked session, which comes back).
    private func notice(_ item: AgentsInbox.Item, title: String, detail: String, since: Date?, provider: String?,
                        primary: String, secondary: String, figure: AnyView) -> some View {
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
                        button(primary, key: "↵", primary: true) { onKey(true, item.id) }
                        Spacer(minLength: 4)
                        button(secondary, key: "esc", primary: false) { inbox.skip(item.id) }
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
        case .blocked(let agent, _): return Localization.string("%@ waits").replacingOccurrences(of: "%@", with: agent.displayTitle)
        case .done(let agent, _): return Localization.string("%@ is done").replacingOccurrences(of: "%@", with: agent.displayTitle)
        case .loop(let loop): return Localization.string("%@ failed").replacingOccurrences(of: "%@", with: loop.displayName)
        }
    }

    /// Every prompt left was skipped this round: they still wait, so no all-clear.
    private func allSkipped(_ count: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.waiting)
                .frame(width: 30, height: 30)
                .background(Theme.waiting.opacity(0.16), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: Localization.string("%d skipped"), count))
                    .font(Theme.font(14, .semibold)).foregroundStyle(Theme.textPrimary)
                Text("Still waiting, back when the inbox opens next").font(Theme.font(12)).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: Self.emptyHeight)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
