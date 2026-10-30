import AppKit
import NotchCore
import Observation
import SwiftUI

/// Quick capture: one field grows out of the notch, the text is read while typing (due date,
/// time, people), ↵ files it through `CaptureInbox`, the character nods, the island closes.
@MainActor
@Observable
final class QuickCapture {
    enum Phase: Equatable { case editing, sent }

    enum Route: String, CaseIterable, Identifiable {
        case task = "Task", question = "Question", note = "Note"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .task: "checklist"
            case .question: "questionmark.bubble"
            case .note: "note.text"
            }
        }
    }

    var text = "" {
        didSet { reparse() }
    }
    var route = Route.task
    var phase = Phase.editing
    /// Dictation into the field (the mic button starts Wispr Flow).
    var dictating = false
    /// What the text says about date, time and people, updated as it changes.
    private(set) var parse = CaptureParse()
    /// Known people (from a `PeopleProvider` connector).
    var people: [Person] = []
    /// Wispr Flow is installed (the mic button shows).
    var canDictate = NSWorkspace.shared.urlForApplication(withBundleIdentifier: DictationModule.bundleID) != nil
    var outcome: CaptureInbox.Outcome?
    /// Where captures land, for the Inbox button and the confirmation (nil: a connector takes them).
    let inboxFile = CaptureInbox.markdownFile
    /// The text named a day and a time and the user added it to the calendar: when.
    var eventAdded: String?

    /// Start of an event the text describes ("Call Ada tomorrow at 15:00").
    var eventStart: Date? { parse.eventStart(calendar: .current) }

    /// The next or previous of Task, Question, Note (wrapping), with a tick.
    func step(_ by: Int) {
        let all = Route.allCases
        let index = all.firstIndex(of: route) ?? 0
        Haptics.tick()
        withAnimation(Theme.snappy) { route = all[(index + by + all.count) % all.count] }
    }

    private func reparse() {
        parse = CaptureParser.parse(text, now: Date(), calendar: .current, people: people)
    }

    /// "today 16:00", "tomorrow", "Fri 24 Oct"
    var dueLabel: String? {
        guard let day = parse.day else { return nil }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let offset = calendar.dateComponents([.day], from: today, to: day).day ?? 0
        var label: String
        switch offset {
        case 0: label = "today"
        case 1: label = "tomorrow"
        default:
            label = day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(Locale(identifier: "en_GB")))
        }
        if let hour = parse.hour { label += String(format: " %02d:%02d", hour, parse.minute ?? 0) }
        return label
    }
}

struct CaptureView: View {
    @Bindable var capture: QuickCapture
    let cast: AvatarCast?
    let notch: CGSize
    let onSend: () -> Void
    let onMic: () -> Void
    var onEvent: (() -> Void)?
    /// The confirmation's buttons: the Notepad on "Tara's notes", the Markdown inbox.
    var onShowNotes: () -> Void = {}
    var onOpenInbox: () -> Void = {}
    @FocusState private var focused: Bool
    @Namespace private var chips

    var body: some View {
        VStack(spacing: 0) {
            // Band beside the notch: the character peeks left, the key hint sits right.
            HStack(spacing: 0) {
                Group {
                    // In the confirmation the character moves into the row (nodding).
                    if let cast, capture.phase == .editing {
                        AvatarView(character: cast.main, mood: capture.phase == .sent ? .finished : .yourTurn,
                                   height: 30, colorway: cast.colorway, sink: 0.3)
                            .frame(height: notch.height, alignment: .bottom)
                            .clipped()
                    }
                }
                .frame(maxWidth: .infinity)
                Color.clear.frame(width: notch.width)
                Text(capture.phase == .sent ? "" : "↵ file  esc  ⌃⌥I inbox")
                    .font(Theme.font(11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity)
            }
            .frame(height: notch.height)

            ZStack {
                if capture.phase == .editing {
                    editing.transition(.blurSlide(y: -8))
                } else {
                    sent.transition(.blurSlide(y: 10, scale: 0.96))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .animation(Theme.open, value: capture.phase)
        .onAppear { focused = true }
    }

    private var editing: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                TextField("What's on your mind?", text: $capture.text)
                    .textFieldStyle(.plain)
                    .font(Theme.font(15))
                    .foregroundStyle(Theme.textPrimary)
                    .focused($focused)
                    .onSubmit(onSend)
                if capture.dictating {
                    ListeningGlyph(active: true, size: 16)
                        .transition(.blurSlide(scale: 0.8))
                }
                // The mic only when Wispr Flow is there to listen.
                if capture.canDictate {
                    Button(action: onMic) {
                        Image(systemName: capture.dictating ? "mic.fill" : "mic")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(capture.dictating ? .white : Theme.accent)
                            .frame(width: 28, height: 28)
                            .background(capture.dictating ? Theme.accent : Theme.accent.opacity(0.14), in: Circle())
                    }
                    .buttonStyle(PressScale())
                    .help("Dictate with Wispr Flow")
                }
                if !capture.text.isEmpty {
                    Button(action: onSend) {
                        Image(systemName: "return")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(PressScale())
                    .transition(.blurSlide(x: 8))
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .frame(height: 44)
            // The whole field takes a click, not only the line of text.
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.card)
                    .onTapGesture { focused = true }
            }
            .animation(Theme.snappy, value: capture.text.isEmpty)
            .animation(Theme.snappy, value: capture.dictating)

            // Where it goes: small, gliding, the choice in the accent.
            HStack(spacing: 2) {
                ForEach(QuickCapture.Route.allCases) { route in
                    let selected = capture.route == route
                    Button {
                        Haptics.tick()
                        withAnimation(Theme.snappy) { capture.route = route }
                        focused = true  // the cursor stays in the field
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: route.symbol).font(.system(size: 10.5, weight: .semibold))
                            Text(route.rawValue).font(Theme.font(12, selected ? .semibold : .regular))
                        }
                        .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Theme.accent.opacity(0.14))
                                    .matchedGeometryEffect(id: "route", in: chips)
                            }
                        }
                        .padding(.vertical, 3)  // a larger target than the chip
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScale())
                }
                // Where the captures are: one click opens the file.
                if let file = capture.inboxFile {
                    Button { CaptureInbox.openMarkdown(file) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "tray.full").font(.system(size: 10.5, weight: .semibold))
                            Text(file.deletingPathExtension().lastPathComponent).font(Theme.font(12))
                        }
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScale())
                    .help("Open \(file.path), where tasks, questions and notes land (⌃⌥I from anywhere)")
                }
                Spacer(minLength: 8)
                // What the text says, as chips (Todoist-style): date in the accent, people neutral.
                HStack(spacing: 6) {
                    if capture.eventStart != nil, let onEvent {
                        Button(action: onEvent) {
                            HStack(spacing: 4) {
                                Image(systemName: "calendar.badge.plus").font(.system(size: 10, weight: .semibold))
                                Text("Event").font(Theme.font(12, .medium))
                            }
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 7)
                            .frame(height: 22)
                            .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(PressScale())
                        .help("Add a one-hour event to your calendar at that time (⌘E)")
                        .keyboardShortcut("e", modifiers: .command)
                        .transition(.blurSlide(x: 6, scale: 0.9))
                    }
                    if let due = capture.dueLabel {
                        chip(symbol: "calendar", text: due, tint: Theme.accent)
                    }
                    ForEach(capture.parse.people.prefix(2), id: \.slug) { person in
                        chip(symbol: "person", text: person.firstName, tint: Theme.textBody)
                    }
                }
                .animation(Theme.snappy, value: capture.parse)
            }
            .padding(.leading, 4)
        }
    }

    private func chip(symbol: String, text: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            Text(text).font(Theme.font(12, .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .transition(.blurSlide(x: 6, scale: 0.9))
    }

    private var sent: some View {
        HStack(spacing: 12) {
            CheckDraw()
            VStack(alignment: .leading, spacing: 2) {
                Text(sentTitle)
                    .font(Theme.font(15, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(sentDetail)
                    .font(Theme.font(12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            // Where it went, one click away: the note flies into the Notepad.
            if capture.eventAdded == nil {
                HStack(spacing: 6) {
                    SentButton(symbol: "note.text", title: "Notepad", help: "Show it in Tools › Notepad › Tara's notes",
                               landing: true, action: onShowNotes)
                    if capture.outcome == .delivered, let file = capture.inboxFile {
                        SentButton(symbol: "doc.text", title: LocalizedStringKey(file.lastPathComponent),
                                   help: "Open \(file.path)", action: onOpenInbox)
                    }
                }
            }
            if let cast {
                NoddingAvatar(character: cast.main, colorway: cast.colorway)
                    .frame(width: 70, height: 64, alignment: .bottom)
            }
        }
        .padding(.leading, 12)
        .frame(height: 64)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

extension CaptureView {
    var sentTitle: String {
        if capture.eventAdded != nil { return "Added to Calendar" }
        if capture.outcome == .delivered, capture.inboxFile == nil { return "In the inbox" }
        return "Saved"
    }

    /// Says where it is: "Kept on this Mac" told nobody where to find it again.
    var sentDetail: String {
        if let when = capture.eventAdded { return when }
        let kind = capture.route.rawValue.lowercased()
        // Connector inbox: no buttons, the text itself.
        if capture.outcome == .delivered, capture.inboxFile == nil { return "\(kind) · \(capture.text)" }
        // The buttons beside it name the places.
        return "as \(kind), find it here"
    }
}

/// A small button in the confirmation. `landing`: a note glyph flies into it once, then it
/// gives a little bump, so the eye follows the capture to where it went.
private struct SentButton: View {
    let symbol: String
    let title: LocalizedStringKey
    let help: String
    var landing = false
    let action: () -> Void
    @State private var flight: CGFloat = 0
    @State private var bump = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold))
                Text(title).font(Theme.font(12, .medium)).lineLimit(1).fixedSize()
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(Theme.accent.opacity(bump ? 0.26 : 0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .scaleEffect(bump ? 1.08 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .help(help)
        .overlay {
            if landing && flight < 1 && !reduceMotion {
                // From the left of the card, in a low arc, shrinking into the button.
                Image(systemName: "note.text")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .scaleEffect(1.3 - 0.6 * flight)
                    .offset(x: -230 * (1 - flight), y: -16 * sin(.pi * flight))
                    .opacity(flight < 0.85 ? 1 : Double((1 - flight) / 0.15))
                    .allowsHitTesting(false)
            }
        }
        .task {
            guard landing, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.55)) { flight = 1 }
            try? await Task.sleep(for: .milliseconds(520))
            Haptics.tick()
            withAnimation(.spring(duration: 0.25, bounce: 0.5)) { bump = true }
            try? await Task.sleep(for: .milliseconds(200))
            withAnimation(.spring(duration: 0.3)) { bump = false }
        }
    }
}

/// A check that draws itself, filled in the "secured" green.
private struct CheckDraw: View {
    @State private var progress: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().fill(Theme.ok.opacity(0.18))
            Path { p in
                p.move(to: CGPoint(x: 9, y: 15.5))
                p.addLine(to: CGPoint(x: 13.5, y: 20))
                p.addLine(to: CGPoint(x: 21.5, y: 10.5))
            }
            .trim(from: 0, to: progress)
            .stroke(Theme.ok, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 30, height: 30)
        .onAppear {
            if reduceMotion { progress = 1 } else {
                withAnimation(.easeOut(duration: 0.35).delay(0.08)) { progress = 1 }
            }
        }
    }
}

/// The character nods twice: happy, it's filed.
private struct NoddingAvatar: View {
    let character: String
    let colorway: Colorway
    @State private var nod: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        AvatarView(character: character, mood: .finished, height: 60, colorway: colorway, sink: 0.05, emergeOnAppear: false)
            .rotationEffect(.degrees(nod), anchor: .bottom)
            .offset(y: nod > 0 ? 2 : 0)
            .task {
                guard !reduceMotion else { return }
                for _ in 0..<2 {
                    withAnimation(.easeInOut(duration: 0.16)) { nod = 7 }
                    try? await Task.sleep(for: .milliseconds(170))
                    withAnimation(.spring(duration: 0.3, bounce: 0.4)) { nod = 0 }
                    try? await Task.sleep(for: .milliseconds(260))
                }
            }
    }
}
