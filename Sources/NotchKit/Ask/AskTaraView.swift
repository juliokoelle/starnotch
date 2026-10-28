import NotchCore
import SwiftUI

/// Beside the floating Tara: her speech bubble (thinking, the answer with its sources, or what
/// went wrong) above the field the question is typed or spoken into.
struct AskTaraView: View {
    @Bindable var ask: AskTara
    @FocusState private var focused: Bool

    static let width: CGFloat = 300

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if showsReply {
                reply
                    .transition(.opacity)
            }
            field
        }
        .frame(width: Self.width, alignment: .trailing)
        .animation(Theme.snappy, value: showsReply)
        .onAppear { focused = true }
        .onChange(of: ask.focusRequest) { _, _ in focused = true }
    }

    private var showsReply: Bool {
        switch ask.phase {
        case .idle, .listening: ask.answer != nil
        case .thinking, .answered, .failed: true
        }
    }

    // MARK: The field

    private var field: some View {
        VStack(alignment: .leading, spacing: 6) {
            if ask.attachment != nil || ask.capturing {
                attachmentChip.transition(.opacity)
            }
            input
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .frame(minHeight: 40)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.accent.opacity(focused || ask.isListening ? 0.6 : 0.3), lineWidth: 1)
        }
        .animation(Theme.snappy, value: ask.isListening)
        .animation(Theme.snappy, value: ask.text.isEmpty)
        .animation(Theme.snappy, value: ask.attachment)
        .help("Drop Tara on a window to ask about it")
    }

    /// The window Tara was dropped on, going with the next question.
    private var attachmentChip: some View {
        HStack(spacing: 6) {
            if ask.capturing {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "macwindow")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            Text(ask.attachment?.app.isEmpty == false ? ask.attachment!.app : Localization.string("This window"))
                .font(Theme.font(11.5, .medium))
                .foregroundStyle(Theme.textBody)
                .lineLimit(1)
            if ask.attachment != nil {
                Button { ask.removeAttachment() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressScale())
                .help("Don't send the window")
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 2)
        .frame(height: 24)
        .background(Theme.accent.opacity(0.12), in: Capsule())
    }

    private var input: some View {
        HStack(spacing: 6) {
            TextField("Ask Tara…", text: $ask.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.font(13))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1...3)
                .focused($focused)
                .onSubmit { ask.send() }
                .onExitCommand { ask.close() }
            if ask.isListening {
                ListeningGlyph(active: true, size: 14)
                    .transition(.opacity)
            }
            Button { ask.toggleListening() } label: {
                Image(systemName: ask.isListening ? "mic.fill" : "mic")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ask.isListening ? .white : Theme.accent)
                    .frame(width: 28, height: 28)
                    .background(ask.isListening ? Theme.accent : Theme.accent.opacity(0.14), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(PressScale())
            .disabled(ask.isThinking)
            .help(Localization.string(ask.isListening ? "Stop and ask" : "Speak (or hold ⌃⌥T)"))
            if !ask.text.trimmingCharacters(in: .whitespaces).isEmpty && !ask.isListening {
                Button { ask.send() } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(ask.isThinking ? Theme.textTertiary : Theme.accent, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(PressScale())
                .disabled(ask.isThinking)
                .help("Ask (↵)")
                .transition(.opacity)
            }
        }
    }

    // MARK: Her speech bubble

    private var reply: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let asked = ask.asked {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(asked)
                        .font(Theme.font(11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    if ask.conversation.turns.count > 0 && !ask.isThinking {
                        Button { ask.startOver() } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.textTertiary)
                                .frame(width: 28, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PressScale())
                        .help("Start over")
                    }
                }
            }
            switch ask.phase {
            case .thinking(let since):
                Thinking(since: since)
            case .failed(let message):
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.waiting)
                    Text(message)
                        .font(Theme.font(12.5))
                        .foregroundStyle(Theme.textBody)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .idle, .listening, .answered:
                if let answer = ask.answer { answerView(answer) }
            }
        }
        .padding(12)
        .frame(width: Self.width, alignment: .leading)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        }
    }

    private func answerText(_ answer: AskAnswer) -> some View {
        Text(answer.text)
            .font(Theme.font(13))
            .foregroundStyle(Theme.textPrimary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func answerView(_ answer: AskAnswer) -> some View {
        // Short answers at their size; a long one (more than about eight lines) scrolls, so the sources stay in view.
        if answer.text.count > 300 {
            ScrollView(.vertical, showsIndicators: false) { answerText(answer) }
                .scrollEdgeFade(bottom: 18)
                .frame(height: 140)
        } else {
            answerText(answer)
        }
        if !answer.sources.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(answer.sources.prefix(4)) { source in
                    SourceRow(source: source, expanded: ask.expanded == source.id) { ask.openSource(source) }
                }
            }
        }
        if answer.onRules {
            Text(LocalizedStringKey(ask.offlineReason == nil ? "Simple rules, no Claude: Settings › Meeting agent"
                                                             : "Claude isn't reachable, so simple rules answered"))
                .font(Theme.font(11))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Tara thinks: three dots, and after a moment the seconds, so a slow answer reads as work.
private struct Thinking: View {
    let since: Date
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // With Reduce Motion the dots stand still, and the seconds still count.
        TimelineView(.periodic(from: since, by: reduceMotion ? 1 : 1 / 20)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let elapsed = Int(context.date.timeIntervalSince(since))
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(Theme.textSecondary)
                            .frame(width: 5, height: 5)
                            .opacity(reduceMotion ? 0.6 : 0.3 + 0.7 * max(0, sin(t * 4 - Double(index) * 0.7)))
                    }
                }
                Text("Thinking")
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.textSecondary)
                if elapsed >= 2 {
                    Text(verbatim: "\(elapsed) s")
                        .font(Theme.font(11).monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .frame(height: 18)
        .accessibilityLabel(Text("Thinking"))
    }
}

/// One source: what it is, its title and date; a click opens it or unfolds its quote.
private struct SourceRow: View {
    let source: AskSource
    let expanded: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HoverRow(cornerRadius: 8, hoverOpacity: 0.08, help: help, action: action) {
                HStack(spacing: 7) {
                    Image(systemName: symbol)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 14)
                    Text(source.title)
                        .font(Theme.font(12, .medium))
                        .foregroundStyle(Theme.textBody)
                        .lineLimit(1)
                    if let day = Self.day(source.date) {
                        Text(day)
                            .font(Theme.font(11.5))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                    Spacer(minLength: 4)
                    if source.url != nil {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(.horizontal, 6)
                .frame(height: 28)
            }
            if expanded && !source.quote.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 1).fill(Theme.accent.opacity(0.55)).frame(width: 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.quote)
                            .lineLimit(4)
                            .font(Theme.font(12).italic())
                            .foregroundStyle(Theme.textBody)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if let speaker = source.speaker {
                            Text(speaker).font(Theme.font(11)).foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
                .padding(.leading, 12)
                .padding(.bottom, 4)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
            }
        }
    }

    private var symbol: String {
        switch source.kind {
        case .meeting: "person.2.fill"
        case .capture: "square.and.pencil"
        case .note: "doc.text"
        }
    }

    private var help: String {
        if source.url != nil { return Localization.string("Open") }
        return source.kind == .meeting ? Localization.string("Show the words from the meeting") : Localization.string("Show the note")
    }

    /// "12 Oct" (in the interface language) from "2026-10-12".
    static func day(_ text: String?) -> String? {
        guard let text, let date = try? Date(text + "T12:00:00Z", strategy: .iso8601) else { return nil }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}
