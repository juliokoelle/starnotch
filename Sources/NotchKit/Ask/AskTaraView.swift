import NotchCore
import SwiftUI

/// Beside the floating Tara: her answer card (thinking, the answer with its sources, or what went
/// wrong) above the field the question is typed or spoken into. The card grows with the answer up
/// to the window's height (about 60 % of the screen) and scrolls from there, always from the start.
struct AskTaraView: View {
    @Bindable var ask: AskTara
    @FocusState private var focused: Bool

    static let width: CGFloat = 380
    static let cardRadius: CGFloat = 20
    static let fieldRadius: CGFloat = 18

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if showsReply {
                card
                    .transition(.opacity.combined(with: .scale(scale: Theme.reduceMotion ? 1 : 0.98, anchor: .bottom)))
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

    /// Apple's recognizer or Wispr Flow is taking the words.
    private var listening: Bool { ask.isListening || ask.isDictating }

    // MARK: The field

    private var field: some View {
        VStack(alignment: .leading, spacing: 8) {
            if ask.attachment != nil || ask.capturing {
                attachmentChip.transition(.opacity)
            }
            input
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .frame(minHeight: 50)
        .background(Glass(cornerRadius: Self.fieldRadius))
        // The rim turns while she listens; while she thinks, the card's rim does.
        .overlay(IridescentRim(cornerRadius: Self.fieldRadius, moving: listening, lit: focused || listening))
        .animation(Theme.snappy, value: listening)
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
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            Text(ask.attachment?.app.isEmpty == false ? ask.attachment!.app : Localization.string("This window"))
                .font(Theme.font(13, .medium))
                .foregroundStyle(Theme.textBody)
                .lineLimit(1)
            if ask.attachment != nil {
                Button { ask.removeAttachment() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressScale())
                .help("Don't send the window")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, ask.attachment == nil ? 10 : 0)
        .frame(height: 28)
        .background(Theme.accent.opacity(0.14), in: Capsule())
    }

    private var input: some View {
        HStack(spacing: 8) {
            TextField(listening && ask.text.isEmpty ? LocalizedStringKey("Listening…") : LocalizedStringKey("Ask Tara…"),
                      text: $ask.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.font(15))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1...4)
                .focused($focused)
                .onSubmit { ask.send() }
                .onExitCommand { ask.close() }
            if listening {
                ListeningGlyph(active: true, size: 16)
                    .transition(.opacity)
            }
            Button { ask.toggleListening() } label: {
                Image(systemName: listening ? "mic.fill" : "mic")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(listening ? .white : Theme.accent)
                    .frame(width: 34, height: 34)
                    .background(listening ? Theme.accent : Theme.accent.opacity(0.14), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(PressScale())
            .disabled(ask.isThinking)
            .help(Localization.string(ask.isDictating ? "Stop dictating" : ask.isListening ? "Stop and ask" : "Speak (or hold ⌃⌥T)"))
            if !ask.text.trimmingCharacters(in: .whitespaces).isEmpty && !listening {
                Button { ask.send() } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
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

    // MARK: Her answer card

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            AnswerScroll(identity: "\(ask.asked ?? "")|\(ask.answer?.text.count ?? -1)") { cardContent }
            if showsActions { actions }
        }
        .frame(width: Self.width, alignment: .leading)
        .background(Glass(cornerRadius: Self.cardRadius))
        .overlay(IridescentRim(cornerRadius: Self.cardRadius, moving: ask.isThinking, lit: ask.isThinking))
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let asked = ask.asked {
                Text(asked)
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch ask.phase {
            case .thinking(let since):
                Thinking(since: since)
            case .failed(let message):
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.waiting)
                    Text(message)
                        .font(Theme.font(14))
                        .lineSpacing(3)
                        .foregroundStyle(Theme.textBody)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .idle, .listening, .answered:
                if let answer = ask.answer { answerView(answer) }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func answerView(_ answer: AskAnswer) -> some View {
        Text(answer.text)
            .font(Theme.font(15))
            .lineSpacing(4)
            .foregroundStyle(Theme.textPrimary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        if answer.onRules {
            Text(LocalizedStringKey(ask.offlineReason == nil ? "Simple rules, no Claude: Settings › Meeting agent"
                                                             : "Tara's model isn't reachable, so simple rules answered"))
                .font(Theme.font(12))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if !answer.sources.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sources")
                    .font(Theme.font(12, .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.bottom, 2)
                ForEach(answer.sources.prefix(4)) { source in
                    SourceRow(source: source, expanded: ask.expanded == source.id) { ask.openSource(source) }
                        .padding(.horizontal, -8)  // the hover fill reaches past the text column
                }
            }
            .padding(.top, 6)
        }
    }

    // MARK: Actions on an answer

    /// An answer worth keeping: not an error, and not the rules saying they found nothing.
    private var hasAnswer: Bool {
        if case .failed = ask.phase { return false }
        guard let answer = ask.answer else { return false }
        return !(answer.onRules && answer.sources.isEmpty)
    }

    private var showsActions: Bool {
        !ask.isThinking && (hasAnswer || ask.conversation.turns.count > 0)
    }

    private var actions: some View {
        HStack(spacing: 2) {
            if hasAnswer {
                ActionButton(symbol: ask.copied ? "checkmark" : "doc.on.doc", title: ask.copied ? "Copied" : "Copy",
                             help: "Copy the answer") { ask.copyAnswer() }
                ActionButton(symbol: saveSymbol, title: saveTitle, help: saveHelp,
                             tint: ask.saved == .failed ? Theme.waiting : nil) { ask.saveAnswer() }
                    .disabled(ask.saved == .notepad || ask.saved == .inbox)
            }
            Spacer(minLength: 4)
            if ask.conversation.turns.count > 0 {
                Button { ask.startOver() } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressScale())
                .help("Start over")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1).padding(.horizontal, 18)
        }
    }

    private var saveSymbol: String {
        switch ask.saved {
        case .notepad, .inbox: "checkmark"
        case .failed: "exclamationmark.circle"
        case nil: "square.and.arrow.down"
        }
    }

    private var saveTitle: LocalizedStringKey {
        switch ask.saved {
        case .notepad: "Saved to the notepad"
        case .inbox: "Saved to the inbox"
        case .failed: "Couldn't save"
        case nil: "Save to notes"
        }
    }

    private var saveHelp: String {
        AskTara.savesToInbox ? "Add the question and answer to your notes inbox"
                             : "Save the question and answer as a note in the notepad"
    }
}

// MARK: Pieces

/// The card's scroll area: as tall as its content, at most what the window leaves, scrolled to
/// the start of each new answer; its bottom edge fades only while there is more below.
private struct AnswerScroll<Content: View>: View {
    let identity: String
    @ViewBuilder var content: Content
    @State private var contentHeight: CGFloat = 0
    @State private var shownHeight: CGFloat = 0

    private static var bottom: CGFloat { 16 }

    var body: some View {
        let overflows = contentHeight > shownHeight - Self.bottom + 1
        ScrollView(.vertical) {
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .contentMargins(.bottom, Self.bottom, for: .scrollContent)
        .scrollIndicators(overflows ? .automatic : .never)
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.top)
        .id(identity)  // a new answer starts at its first line, never where the last one was left
        .mask(VStack(spacing: 0) {
            Color.black
            LinearGradient(colors: [.black, overflows ? .clear : .black], startPoint: .top, endPoint: .bottom)
                .frame(height: 28)
        })
        .frame(maxHeight: contentHeight + Self.bottom)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { shownHeight = $0 }
    }
}

/// A dark, glassy surface: near black with a faint light along the top edge.
private struct Glass: View {
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape.fill(Color(hex: 0x0B0B0E))
            .overlay(shape.fill(LinearGradient(colors: [Color.white.opacity(0.07), .clear],
                                               startPoint: .top, endPoint: .center)))
            .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
    }
}

/// The one striking moment: a liquid chrome rim with a prismatic sheen (red-orange through
/// violet to blue), after the new Apple Music icon. It turns slowly while Tara listens or thinks
/// and stands still otherwise; with Reduce Motion it never turns.
struct IridescentRim: View {
    var cornerRadius: CGFloat
    var moving: Bool
    /// Brighter while it has something to say: focused, listening or thinking.
    var lit: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Two prismatic highlights on brushed chrome, opposite each other.
    static let sheen = AngularGradient(gradient: Gradient(stops: [
        .init(color: .white.opacity(0.16), location: 0.00),
        .init(color: Color(hex: 0xFF5A36), location: 0.07),
        .init(color: Color(hex: 0xFF3D8B), location: 0.12),
        .init(color: Color(hex: 0x8B5CFF), location: 0.17),
        .init(color: Color(hex: 0x3D7BFF), location: 0.22),
        .init(color: Color(hex: 0x6FE3FF), location: 0.27),
        .init(color: .white.opacity(0.85), location: 0.31),
        .init(color: .white.opacity(0.16), location: 0.40),
        .init(color: .white.opacity(0.08), location: 0.52),
        .init(color: .white.opacity(0.55), location: 0.60),
        .init(color: Color(hex: 0x6FE3FF), location: 0.64),
        .init(color: Color(hex: 0x3D7BFF), location: 0.68),
        .init(color: Color(hex: 0x8B5CFF), location: 0.72),
        .init(color: Color(hex: 0xFF3D8B), location: 0.77),
        .init(color: Color(hex: 0xFF5A36), location: 0.82),
        .init(color: .white.opacity(0.16), location: 0.90),
        .init(color: .white.opacity(0.16), location: 1.00),
    ]), center: .center)

    /// Where the highlights rest: top left and bottom right, like light from above.
    private static let restAngle = -28.0
    /// One turn in this many seconds.
    private static let turn = 8.0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let turning = moving && !reduceMotion
        GeometryReader { geo in
            // The gradient's square covers the whole shape at any angle.
            let side = (geo.size.width * geo.size.width + geo.size.height * geo.size.height).squareRoot()
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !turning)) { context in
                let elapsed = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.turn)
                let angle = Self.restAngle + (turning ? elapsed / Self.turn * 360 : 0)
                ZStack {
                    if moving {
                        // A soft glow just outside the rim while she works.
                        sheet(side: side, angle: angle, in: geo.size)
                            .mask(shape.stroke(lineWidth: 6))
                            .blur(radius: 6)
                            .opacity(0.5)
                            .transition(.opacity)
                    }
                    sheet(side: side, angle: angle, in: geo.size)
                        .mask(shape.strokeBorder(lineWidth: 1.25))
                        .opacity(lit ? 1 : 0.55)
                }
            }
        }
        .animation(.easeOut(duration: 0.3), value: lit)
        .animation(.easeOut(duration: 0.3), value: moving)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func sheet(side: CGFloat, angle: Double, in size: CGSize) -> some View {
        Rectangle().fill(Self.sheen)
            .frame(width: side, height: side)
            .rotationEffect(.degrees(angle))
            .frame(width: size.width, height: size.height)
    }
}

/// A small action under the answer: symbol and label.
private struct ActionButton: View {
    let symbol: String
    let title: LocalizedStringKey
    let help: String
    var tint: Color?
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HoverRow(cornerRadius: 8, hoverOpacity: isEnabled ? 0.08 : 0, help: Localization.string(help), action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 14)
                Text(title)
                    .font(Theme.font(13, .medium))
                    .lineLimit(1)
            }
            // Done (disabled) reads brighter: the check confirms it.
            .foregroundStyle(tint ?? (isEnabled ? Theme.textSecondary : Theme.textBody))
            .padding(.horizontal, 8)
            .frame(height: 32)
        }
    }
}

/// Tara thinks: the answer's shape breathes, and after a moment the seconds count, so a slow
/// answer reads as work.
private struct Thinking: View {
    let since: Date
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach([1.0, 0.94, 0.58], id: \.self) { width in
                    Capsule()
                        .fill(Color.white.opacity(0.09))
                        .frame(height: 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .scaleEffect(x: width, y: 1, anchor: .leading)
                }
            }
            .opacity(breathing ? 1 : 0.45)
            TimelineView(.periodic(from: since, by: 1)) { context in
                let elapsed = Int(context.date.timeIntervalSince(since))
                HStack(spacing: 6) {
                    Text("Thinking")
                        .font(Theme.font(13))
                        .foregroundStyle(Theme.textSecondary)
                    if elapsed >= 2 {
                        Text(verbatim: "\(elapsed) s")
                            .font(Theme.font(13).monospacedDigit())
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
        }
        .padding(.top, 2)
        .onAppear {
            // With Reduce Motion the shape stands still; the seconds still count.
            guard !reduceMotion else { return breathing = true }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { breathing = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Thinking"))
    }
}

/// One source: what it is, its title and date; a click opens it or unfolds its quote, which
/// also shows on hover.
private struct SourceRow: View {
    let source: AskSource
    let expanded: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HoverRow(cornerRadius: 8, hoverOpacity: 0.07, help: help, action: action) {
                HStack(spacing: 8) {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 16)
                    Text(source.title)
                        .font(Theme.font(13, .medium))
                        .foregroundStyle(Theme.textBody)
                        .lineLimit(1)
                    if let day = Self.day(source.date) {
                        Text(day)
                            .font(Theme.font(12))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                    Spacer(minLength: 4)
                    if source.url != nil {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                    } else if unfolds {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 32)
            }
            if expanded && !source.quote.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 1).fill(Theme.accent.opacity(0.55)).frame(width: 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(source.quote)
                            .lineLimit(6)
                            .font(Theme.font(14))
                            .lineSpacing(3)
                            .foregroundStyle(Theme.textBody)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if let speaker = source.speaker {
                            Text(speaker).font(Theme.font(12)).foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
                .padding(.leading, 15)
                .padding(.trailing, 8)
                .padding(.vertical, 4)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
            }
        }
    }

    /// A meeting with words to show unfolds in place.
    private var unfolds: Bool { source.kind == .meeting && !source.quote.isEmpty }

    private var symbol: String {
        switch source.kind {
        case .meeting: "person.2.fill"
        case .capture: "square.and.pencil"
        case .note: "doc.text"
        }
    }

    private var help: String {
        if source.url != nil { return Localization.string("Open") }
        if unfolds, !expanded { return source.quote.count > 240 ? String(source.quote.prefix(239)) + "…" : source.quote }
        return source.kind == .meeting ? Localization.string("Show the words from the meeting") : Localization.string("Show the note")
    }

    /// "12 Oct" (in the interface language) from "2026-10-12".
    static func day(_ text: String?) -> String? {
        guard let text, let date = try? Date(text + "T12:00:00Z", strategy: .iso8601) else { return nil }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}
