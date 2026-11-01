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

    /// What is picked so far in Claude Code's questions (`AskUserQuestion`), per request: the
    /// question in view, the options picked for each question, a typed answer for each.
    struct QuestionDraft: Equatable {
        var step = 0
        var picks: [Int: Set<Int>] = [:]
        var typed: [Int: String] = [:]
    }

    private(set) var queue: [Pending] = []
    var current: Pending? { queue.first }
    private(set) var drafts: [String: QuestionDraft] = [:]
    /// The request whose Deny is being given a note ("Instead…"), and the note so far.
    private(set) var notingID: String?
    var note = ""
    /// A session's own window is in front: a question for it is asked there, at once.
    @ObservationIgnored var isSessionInFront: ((ApprovalRequest) -> Bool)?
    /// ↵ in the answer field and the island's ↵ can both arrive for one press.
    @ObservationIgnored private var lastStep = Date.distantPast
    /// Shown (and the island opened) when a request arrives.
    @ObservationIgnored var onShow: (() -> Void)?
    @ObservationIgnored var onEmpty: (() -> Void)?
    /// The pending requests changed (their sessions show "waiting for you").
    @ObservationIgnored var onChange: (([ApprovalRequest]) -> Void)?
    /// A status hook of another tool came in on the same socket (Cursor, Copilot CLI, Gemini CLI, opencode).
    @ObservationIgnored var onHookEvent: ((Data) -> Void)?
    @ObservationIgnored private var server: ApprovalServer?
    /// "Allow for session" for Cursor and Copilot CLI, whose hooks can't carry a rule.
    @ObservationIgnored private var allowances = SessionAllowances()

    static var socketPath: String { Brand.supportFolder.appending(path: "approvals.sock").path }

    func start() {
        let server = ApprovalServer(path: Self.socketPath, handler: { [weak self] request, reply in
            Task { @MainActor in self?.receive(request, reply: reply) }
        }, onCancel: { [weak self] id in
            Task { @MainActor in self?.remove(id) }
        }, onEvent: { [weak self] data in
            Task { @MainActor in self?.onHookEvent?(data) }
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
        // Allowed for this session from the notch before: answered at once, no card.
        if allowances.covers(request) {
            reply(.allowOnce)
            return
        }
        // A question while its session's window is in front: the user sees it there.
        if !request.questions.isEmpty, isSessionInFront?(request) == true {
            reply(nil)
            return
        }
        let wasEmpty = queue.isEmpty
        withAnimation(Theme.snappy) { queue.append(Pending(request: request, reply: reply)) }
        onChange?(queue.map(\.request))
        if wasEmpty { show() }
        // Unanswered: Claude Code's own prompt takes over.
        let id = request.id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(request.timeout))
            self?.expire(id)
        }
    }

    private func show() {
        Haptics.open()
        onShow?()
    }

    /// Answers the request in front, or the one with `id` (the inbox works through any of them).
    func answer(_ decision: ApprovalDecision, to id: String? = nil) {
        guard let pending = id.map({ id in queue.first { $0.id == id } }) ?? queue.first else { return }
        // Codex can't take a session rule: ⌘↵ does nothing there rather than something else.
        if decision == .allowSession, !pending.request.supportsSessionRules { return }
        // A question with answers to pick or type: ↵ alone doesn't pick one.
        if pending.request.asksForAnswer, decision == .allowOnce || decision == .allowSession { return }
        Haptics.confirm()
        if decision == .allowSession { allowances.allow(pending.request) }
        pending.reply(decision)
        remove(pending.id)
    }

    private func expire(_ id: String) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[index].reply(nil)
        remove(id)
    }

    /// "Answer in the terminal" (esc on a question): no answer from the notch, so Claude Code
    /// asks in its own window right away.
    func passThrough(_ id: String? = nil) {
        guard let pending = id.map({ id in queue.first { $0.id == id } }) ?? queue.first else { return }
        Haptics.tick()
        pending.reply(nil)
        remove(pending.id)
    }

    // MARK: Questions (AskUserQuestion)

    func draft(_ id: String) -> QuestionDraft { drafts[id] ?? QuestionDraft() }

    private func question(_ id: String?) -> Pending? {
        let pending = id.map { id in queue.first { $0.id == id } } ?? queue.first
        return pending.flatMap { $0.request.questions.isEmpty ? nil : $0 }
    }

    /// Option `index` of the question in view: a single choice is the answer and moves on (or
    /// sends, on the last question); with several allowed it toggles.
    func pick(_ index: Int, in id: String? = nil) {
        guard let pending = question(id) else { return }
        var draft = draft(pending.id)
        let question = pending.request.questions[min(draft.step, pending.request.questions.count - 1)]
        guard question.options.indices.contains(index) else { return }
        Haptics.tick()
        if question.multiSelect {
            var picked = draft.picks[draft.step] ?? []
            if picked.contains(index) { picked.remove(index) } else { picked.insert(index) }
            draft.picks[draft.step] = picked
            drafts[pending.id] = draft
        } else {
            draft.picks[draft.step] = [index]
            draft.typed[draft.step] = nil
            drafts[pending.id] = draft
            step(pending)
        }
    }

    func type(_ text: String, in id: String) {
        var draft = draft(id)
        draft.typed[draft.step] = text
        drafts[id] = draft
    }

    /// The question in view has a pick or typed text.
    func isAnswered(_ id: String) -> Bool {
        guard let pending = question(id) else { return false }
        let draft = draft(id)
        let question = pending.request.questions[min(draft.step, pending.request.questions.count - 1)]
        return pending.request.answers(picks: draft.picks, typed: draft.typed)[question.text] != nil
    }

    /// ↵ or Next: on to the next question once this one is answered; the last sends them all.
    func next(_ id: String? = nil) {
        guard let pending = question(id), isAnswered(pending.id) else { return }
        // One press can arrive twice (the field's ↵ and the island's).
        guard Date().timeIntervalSince(lastStep) > 0.25 else { return }
        step(pending)
    }

    func back(_ id: String? = nil) {
        guard let pending = question(id) else { return }
        var draft = draft(pending.id)
        guard draft.step > 0 else { return }
        Haptics.tick()
        withAnimation(Theme.snappy) { draft.step -= 1; drafts[pending.id] = draft }
    }

    private func step(_ pending: Pending) {
        lastStep = Date()
        var draft = draft(pending.id)
        if draft.step + 1 < pending.request.questions.count {
            withAnimation(Theme.snappy) { draft.step += 1; drafts[pending.id] = draft }
        } else {
            answer(.answers(pending.request.answers(picks: draft.picks, typed: draft.typed)), to: pending.id)
        }
    }

    // MARK: Deny with a note

    func startNote(_ id: String? = nil) {
        guard let pending = id.map({ id in queue.first { $0.id == id } }) ?? queue.first, pending.request.takesNote else { return }
        Haptics.tick()
        note = ""
        withAnimation(Theme.snappy) { notingID = pending.id }
    }

    func cancelNote() {
        withAnimation(Theme.snappy) { notingID = nil }
        note = ""
    }

    /// Deny, with the note as what to do instead (a plain deny when it's empty).
    func sendNote() {
        guard let id = notingID else { return }
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        answer(text.isEmpty ? .deny : .decline(text), to: id)
    }

    /// Answered in the terminal, or timed out.
    private func remove(_ id: String) {
        drafts[id] = nil
        if notingID == id { notingID = nil; note = "" }
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        if index == 0 { advance() } else { queue.remove(at: index); onChange?(queue.map(\.request)) }
    }

    private func advance() {
        withAnimation(Theme.snappy) { _ = queue.removeFirst() }
        onChange?(queue.map(\.request))
        if queue.isEmpty { onEmpty?() } else { show() }
    }
}

/// An agent's question with answers: up to four to pick (1–4), a field to type one, and Skip.
private struct QuestionAnswers: View {
    let center: ApprovalCenter
    let request: ApprovalRequest
    /// In the agents inbox esc moves on and leaves the question open, so its button says what it does.
    var inInbox = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !request.options.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(request.options.enumerated()), id: \.offset) { index, option in
                        let pick = Button { center.answer(.answer(option), to: request.id) } label: {
                            HStack(spacing: 5) {
                                Text("\(index + 1)").font(Theme.font(10.5, .bold)).foregroundStyle(Theme.textTertiary)
                                Text(option).font(Theme.font(12.5, .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(Color.white.opacity(0.09), in: Capsule())
                            .contentShape(Capsule())
                        }
                        .buttonStyle(PressScale())
                        // Number keys pick, unless they belong in the text field.
                        if request.freeText {
                            pick
                        } else {
                            pick.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [])
                        }
                    }
                }
            }
            if request.freeText {
                HStack(spacing: 8) {
                    TextField("Type an answer", text: $text)
                        .textFieldStyle(.plain)
                        .font(Theme.font(12.5))
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .focused($focused)
                        .onSubmit(send)
                    Button("Send", action: send)
                        .buttonStyle(PressScale())
                        .font(Theme.font(12, .semibold))
                        .foregroundStyle(Theme.accent)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .onAppear { focused = true }
            }
            HStack {
                Spacer()
                Button(LocalizedStringKey(inInbox ? "Don't answer" : "Skip")) { center.answer(.deny, to: request.id) }
                    .buttonStyle(PressScale())
                    .font(Theme.font(11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .help(Localization.string(inInbox ? "The agent hears that you didn't answer" : "The agent hears that you didn't answer (esc)"))
            }
        }
    }

    private func send() {
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return }
        center.answer(.answer(answer), to: request.id)
    }
}

/// The note for "Instead…", focused as it appears.
private struct NoteField: View {
    @Bindable var center: ApprovalCenter
    @FocusState private var focused: Bool

    var body: some View {
        TextField("What should it do instead?", text: $center.note)
            .textFieldStyle(.plain)
            .font(Theme.font(12.5))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .focused($focused)
            .onSubmit { center.sendNote() }
            .onAppear { focused = true }
    }
}

/// Claude Code's questions (`AskUserQuestion`), one at a time: the options to pick (1–9; with
/// several allowed, each toggles), a field for an answer of your own, Back and Next, and
/// "Answer in terminal" (esc), which hands the question back to Claude Code's own window.
private struct QuestionForm: View {
    let center: ApprovalCenter
    let request: ApprovalRequest
    @FocusState private var typing: Bool

    var body: some View {
        let draft = center.draft(request.id)
        let index = min(draft.step, request.questions.count - 1)
        let question = request.questions[index]
        let picked = draft.picks[index] ?? []
        let last = index == request.questions.count - 1
        VStack(alignment: .leading, spacing: 8) {
            Text(question.text)
                .font(Theme.font(13.5, .medium)).foregroundStyle(Theme.textBody)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(question.text)
            VStack(spacing: 4) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { number, option in
                    optionRow(option, number: number, picked: picked.contains(number), multi: question.multiSelect)
                }
            }
            TextField(question.multiSelect ? "Add an answer of your own" : "Or type your own answer", text: Binding(
                get: { center.draft(request.id).typed[index] ?? "" },
                set: { center.type($0, in: request.id) }))
                .textFieldStyle(.plain)
                .font(Theme.font(12.5))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .focused($typing)
                .onSubmit { center.next(request.id) }
            HStack(spacing: 8) {
                if index > 0 {
                    Button("Back") { center.back(request.id) }
                        .buttonStyle(PressScale())
                        .font(Theme.font(12, .medium)).foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 4)
                Button { center.passThrough(request.id) } label: {
                    HStack(spacing: 6) {
                        Text("Answer in terminal").font(Theme.font(12, .medium))
                        Text("esc").font(Theme.font(10.5, .medium)).opacity(0.6)
                    }
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(PressScale())
                .help(Localization.string("Claude asks in its own window instead. Without an answer here, it does so after 60 s."))
                Button { center.next(request.id) } label: {
                    HStack(spacing: 6) {
                        Text(last ? "Send" : "Next").font(Theme.font(12.5, .semibold))
                        Text("↵").font(Theme.font(10.5, .medium)).opacity(0.6)
                    }
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(PressScale())
                .disabled(!center.isAnswered(request.id))
                .opacity(center.isAnswered(request.id) ? 1 : 0.45)
            }
        }
        .onChange(of: draft.step) { typing = false }
    }

    private func optionRow(_ option: ApprovalRequest.Question.Option, number: Int, picked: Bool, multi: Bool) -> some View {
        Button { center.pick(number, in: request.id) } label: {
            HStack(spacing: 8) {
                Text("\(number + 1)").font(Theme.font(10.5, .bold)).foregroundStyle(Theme.textTertiary).frame(width: 12)
                Text(option.label).font(Theme.font(12.5, .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                if let detail = option.detail {
                    Text(detail).font(Theme.font(11.5)).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 4)
                if multi {
                    Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(picked ? Theme.accent : Theme.textTertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(picked ? Theme.accent.opacity(0.2) : Color.white.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .help(option.detail.map { "\(option.label): \($0)" } ?? option.label)
    }
}

/// "<Session> wants to run …": the request, the session's character waiting, and the three answers.
struct ApprovalCard: View {
    let center: ApprovalCenter
    let pending: ApprovalCenter.Pending
    let agents: AgentsModule?
    /// In the agents inbox, ⌘↵ opens the session and esc moves on, so those keys aren't shown here.
    var inInbox = false

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
    /// Claude Code's questions with options (`AskUserQuestion`).
    private var isAskForm: Bool { !pending.request.questions.isEmpty }

    /// The card's height: buttons, an MCP question's options and field, or Claude Code's
    /// questions sized for the one with the most options, so the card doesn't jump between them.
    static func height(for request: ApprovalRequest, inbox: Bool = false) -> CGFloat {
        if !request.questions.isEmpty {
            let options = CGFloat(request.questions.map(\.options.count).max() ?? 2)
            return 138 + options * 34 - 4
        }
        if inbox { return request.freeText ? 196 : request.asksForAnswer ? 172 : 150 }
        return request.asksForAnswer ? 196 : 150
    }

    var body: some View {
        let request = pending.request
        let title = agent?.displayTitle ?? request.cwd.map { ($0 as NSString).lastPathComponent } ?? "A session"
        let headline = isAskForm ? "\(title) asks" : isQuestion ? "\(request.tool) asks" : "\(title) wants to \(verb)"
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
                        if isAskForm {
                            let step = min(center.draft(request.id).step, request.questions.count - 1)
                            if let header = request.questions[step].header {
                                Text(header).font(Theme.font(11, .semibold)).foregroundStyle(Theme.accent)
                                    .padding(.horizontal, 7).frame(height: 18)
                                    .background(Theme.accent.opacity(0.14), in: Capsule())
                                    .lineLimit(1)
                            }
                            if request.questions.count > 1 {
                                Text(String(format: Localization.string("%lld of %lld"), step + 1, request.questions.count))
                                    .font(Theme.font(11.5)).foregroundStyle(Theme.textTertiary).monospacedDigit()
                            }
                        }
                        Spacer(minLength: 6)
                        if center.queue.count > 1 && !inInbox {
                            Text("+\(center.queue.count - 1) waiting").font(Theme.font(11.5)).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    if isAskForm {
                        QuestionForm(center: center, request: request)
                    } else {
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
                    if isQuestion && request.asksForAnswer {
                        QuestionAnswers(center: center, request: request, inInbox: inInbox)
                    } else if center.notingID == pending.id {
                        noteRow(request)
                    } else {
                    HStack(spacing: 8) {
                        button(isQuestion ? "Yes" : "Allow once", key: "↵", style: .primary) { center.answer(.allowOnce, to: pending.id) }
                        if request.supportsSessionRules {
                            button("Allow for session", key: inInbox ? "" : "⌘↵", style: .secondary) { center.answer(.allowSession, to: pending.id) }
                        }
                        Spacer(minLength: 4)
                        if request.takesNote {
                            Button("Instead…") { center.startNote(pending.id) }
                                .buttonStyle(PressScale())
                                .font(Theme.font(12, .medium)).foregroundStyle(Theme.textSecondary)
                                .help(Localization.string("Deny and tell the agent what to do instead"))
                        }
                        button(isQuestion ? "No" : "Deny", key: inInbox ? "" : "esc", style: .quiet) { center.answer(.deny, to: pending.id) }
                    }
                    }
                    Text(isQuestion ? "Unanswered, \(request.tool) hears no answer after \(Int(request.timeout)) s."
                         : "Unanswered, \(request.provider == CodexProvider.id ? "Codex" : request.provider == CursorProvider.id ? "Cursor" : "the terminal") asks after \(Int(request.timeout)) s.")
                        .font(Theme.font(10.5)).foregroundStyle(Theme.textTertiary)
                    }
                }
            }
        }
    }

    private enum Style { case primary, secondary, quiet }

    /// "Instead…": what the agent should do instead of this, sent with the deny (↵), or back (esc).
    private func noteRow(_ request: ApprovalRequest) -> some View {
        HStack(spacing: 8) {
            NoteField(center: center)
            button("Deny and send", key: "↵", style: .primary) { center.sendNote() }
            button("Back", key: "esc", style: .quiet) { center.cancelNote() }
        }
    }

    private func button(_ title: String, key: String, style: Style, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(Theme.font(12.5, .semibold))
                if !key.isEmpty { Text(key).font(Theme.font(10.5, .medium)).opacity(0.6) }
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
