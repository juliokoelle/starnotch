import AppKit
import NotchCore
import Observation
import SwiftUI

/// Ask Tara: ⌃⌥T, or a click on Tara floating beside the notch, opens a question bubble beside
/// her. Type, or hold the keys (or click the mic) to speak; the question goes to an `agent.py` of
/// its own (agent/PROTOCOL.md, `ask`), which answers through Tara's brain from the meetings,
/// quick captures and connector snapshots. The answer appears in her speech bubble with its
/// sources; follow-ups keep a short conversation; esc closes.
@MainActor
@Observable
final class AskTara {
    enum Phase: Equatable {
        case idle
        case listening
        case thinking(since: Date)
        case answered
        /// Something went wrong with this question; the text says what.
        case failed(String)
    }

    private(set) var isOpen = false
    /// The question being typed or spoken.
    var text = "" {
        didSet { pickUpDroppedFile(after: oldValue) }
    }
    private(set) var phase = Phase.idle
    /// Counts files Tara took (dropped on her or the bubble): she hops each time.
    private(set) var received = 0
    /// A file just came in: she looks pleased for a moment.
    private(set) var justReceived = false
    /// The question that was sent, shown above the answer.
    private(set) var asked: String?
    private(set) var answer: AskAnswer?
    /// Why Claude isn't thinking, when the agent said so (shown under a rules answer).
    private(set) var offlineReason: String?
    /// The source whose quote is unfolded.
    var expanded: String?
    /// Bumped to put the keyboard focus back in the field.
    private(set) var focusRequest = 0
    private(set) var conversation = AskConversation()
    /// The bubble's earlier questions in this chat, shown above the one on screen.
    private(set) var thread = AskThread()
    /// The bubble keeps its chats on this Mac and can go back to them (the notch's Ask Tara; the
    /// Dashboard's chats don't).
    @ObservationIgnored var keepsHistory = false
    /// The list of earlier chats shows instead of the answer.
    private(set) var showsChats = false
    private(set) var chats: [AskChat] = []
    /// The chat on screen, as it is kept: grows with every answer.
    @ObservationIgnored private var chat = AskChat()
    private static var history: AskHistory { AskHistory(file: Brand.supportFolder.appending(path: "ask-chats.json")) }
    /// Questions about one day only (the Timeline's day page); nil asks the whole memory.
    var scope: AskScope?
    /// A window Tara was dropped on: its picture goes with the next question.
    struct Attachment: Equatable {
        let url: URL
        let app: String
    }
    private(set) var attachment: Attachment?
    /// A document dropped on Tara in the notch: its text goes with the next question (the file stays untouched).
    private(set) var document: AskDocument?
    /// The window's picture is being taken.
    private(set) var capturing = false
    /// The answer went to the clipboard a moment ago.
    private(set) var copied = false
    /// Where "Save to notes" put the answer, or that it couldn't.
    enum Saved: Equatable { case notepad, inbox, failed }
    private(set) var saved: Saved?
    /// A short word under the field, such as Wispr Flow not starting; it goes after a few seconds.
    private(set) var notice: String?

    /// The bubble opens beside Tara: the companion comes out if needed and takes the keyboard.
    @ObservationIgnored var onOpen: () -> Void = {}
    /// Screen context for a question (and the day it is scoped to, "YYYY-MM-DD"); empty while that source is off.
    @ObservationIgnored var screenContext: ((String, String?, String?) async -> [ScreenAskItem])?
    /// The app in front when Tara was asked to open (⌃⌥T over its window): its screen text goes
    /// with the questions. Not Starnotch itself (the Dashboard's chat).
    @ObservationIgnored private var frontApp: String?
    /// Apps on Tara's ignore list: she never takes a picture of their windows.
    @ObservationIgnored var ignores: (String?) -> Bool = { _ in false }
    @ObservationIgnored var onClose: () -> Void = {}
    /// A question goes out and replaces the one on screen (the Dashboard's chat keeps that one).
    @ObservationIgnored var willAsk: () -> Void = {}
    /// Wispr Flow: when it's installed, the mic starts its hands-free dictation (launching it if
    /// needed), which pastes into the field.
    @ObservationIgnored var wispr: DictationModule? {
        didSet { wispr?.onPhase = { [weak self] phase in self?.wisprChanged(phase) } }
    }
    /// The mic started Wispr Flow from here (its own state says whether it still listens).
    private var dictatingHere = false
    /// Wispr Flow didn't start from this bubble: the mic uses Apple's recognizer until it closes.
    @ObservationIgnored private var wisprDidntStart = false
    /// Esc or quitting while Wispr Flow dictates: the bubble waits for its paste before it goes.
    @ObservationIgnored private var closingAfterDictation = false
    @ObservationIgnored private var noticeReset: Task<Void, Never>?
    /// The notepad, where "Save to notes" writes when no notes vault is connected.
    @ObservationIgnored var notes: NotesStore?
    @ObservationIgnored private var copiedReset: Task<Void, Never>?

    @ObservationIgnored private var process: MeetingProcess?
    @ObservationIgnored private var processBrain: TaraBrain?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pending: String?
    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private var idleEnd: Task<Void, Never>?
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private var holdTask: Task<Void, Never>?
    @ObservationIgnored private var gesture = AskHotKeyGesture()
    @ObservationIgnored private let speech = AskSpeech()
    /// What was typed before speaking started; the spoken words go after it.
    @ObservationIgnored private var typedBeforeSpeaking = ""
    /// Previews: made-up states, no agent.
    @ObservationIgnored private var previewing = false
    /// The picture sent with the pending question, deleted once it's answered.
    @ObservationIgnored private var sentImage: URL?
    /// The recognizer's words still count: from the start of listening until its final result, or
    /// a short wait after the microphone stops (the last words arrive after it).
    @ObservationIgnored private var collectingSpeech = false
    /// Counts listening sessions, so a late result or deadline of an earlier one changes nothing.
    @ObservationIgnored private var speechSession = 0
    /// The question goes out once the last words are in.
    @ObservationIgnored private var sendAfterSpeech = false
    /// Listening was asked for and not called off while macOS asks for permission.
    @ObservationIgnored private var listenWanted = false
    /// `--sample-data` and `--preview`: the demo meetings instead of the user's, no captures or
    /// connectors, and no permission prompts.
    @ObservationIgnored private let demo: Bool

    /// Where window pictures are written; the brain folder, next to Claude Code's prompt files.
    private static var shotFolder: URL { Brand.supportFolder.appending(path: "brain") }

    /// The agent ends this long after the last question, so the next one within it is quick.
    private static let idleLife: Duration = .seconds(300)
    /// A question gets this long before Tara gives up (Claude Code's own limit is 30 s, 60 s with a screenshot).
    private static let patience: Duration = .seconds(75)

    private var log: URL { Brand.supportFolder.appending(path: "tara-ask.log") }

    var isThinking: Bool {
        if case .thinking = phase { return true }
        return false
    }

    var isListening: Bool { phase == .listening }

    /// Wispr Flow dictates into the field; it ends with a second press or by itself.
    var isDictating: Bool {
        guard dictatingHere, let wispr else { return false }
        switch wispr.phase {
        case .starting, .listening: return true
        case .idle, .sent, .unavailable: return false
        }
    }

    init(demo: Bool = false) {
        self.demo = demo
        AskWindowShot.removeLeftovers(in: Self.shotFolder)  // a crash or force quit left them
    }

    /// Tara's face while the bubble is open.
    var mood: AvatarMood? {
        guard isOpen else { return nil }
        if isDictating { return .listening }
        if justReceived { return .finished }
        switch phase {
        case .thinking: return .thinking
        case .listening: return .listening
        case .answered: return answer?.onRules == true ? .idle : .finished
        case .failed: return .failed
        case .idle: return .yourTurn
        }
    }

    // MARK: Opening and closing

    func toggle() {
        isOpen ? close() : open()
    }

    func open() {
        idleEnd?.cancel()
        if !isOpen {
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            frontApp = front == Bundle.main.bundleIdentifier ? nil : front
            withAnimation(Theme.reduceMotion ? nil : Theme.snappy) { isOpen = true }
            Haptics.open()
        }
        onOpen()
        focusRequest += 1
        if !previewing { _ = startAgent() }  // warm: by the time the question is typed, the agent is ready
    }

    func close() {
        guard isOpen, !closingAfterDictation else { return }
        if isDictating {
            closingAfterDictation = true
            finishDictation { [weak self] in
                self?.closingAfterDictation = false
                self?.close()
            }
            return
        }
        holdTask?.cancel()
        cancelSpeech()
        stopDictating()
        timeout?.cancel()
        pending = nil
        withAnimation(Theme.reduceMotion ? nil : Theme.close) {
            isOpen = false
            text = ""
            asked = nil
            answer = nil
            expanded = nil
            phase = .idle
        }
        resetActions()
        setNotice(nil)
        wisprDidntStart = false
        conversation.clear()
        endChat()
        document = nil
        removeAttachment()
        removeSentImage()
        onClose()
        scheduleIdleEnd()
    }

    /// A fresh conversation, the bubble stays.
    func startOver() {
        Haptics.tick()
        timeout?.cancel()
        pending = nil
        withAnimation(Theme.snappy) {
            asked = nil
            answer = nil
            expanded = nil
            phase = .idle
        }
        resetActions()
        conversation.clear()
        endChat()
        focusRequest += 1
    }

    // MARK: Earlier chats

    /// The chat on screen is kept already (after each answer); the next question starts a new one.
    private func endChat() {
        thread.clear()
        chat = AskChat()
        showsChats = false
    }

    /// The list of earlier chats, or back to the chat on screen.
    func toggleChats() {
        Haptics.tick()
        if !showsChats { chats = Self.history.load() }
        withAnimation(Theme.snappy) { showsChats.toggle() }
    }

    /// Carries on with an earlier chat: its questions above, the last answer on screen, and the
    /// follow-ups knowing what was said.
    func resume(_ earlier: AskChat) {
        guard let last = earlier.turns.last, !isThinking else { return }
        Haptics.tick()
        timeout?.cancel()
        pending = nil
        resetActions()
        thread.clear()
        conversation.clear()
        for turn in earlier.turns.dropLast() {
            thread.archive(question: turn.question, answer: turn.answer, failure: nil)
        }
        for turn in earlier.turns { conversation.append(question: turn.question, answer: turn.answer.text) }
        chat = earlier
        withAnimation(Theme.snappy) {
            asked = last.question
            answer = last.answer
            expanded = nil
            phase = .answered
            showsChats = false
        }
        focusRequest += 1
    }

    func deleteChat(_ id: String) {
        Haptics.tick()
        withAnimation(Theme.snappy) { chats = Self.history.delete(id) }
        if chat.id == id { chat = AskChat(turns: []) }
    }

    /// New meetings came into the memory: a running agent re-reads it, so the next question sees them.
    func reloadMemory() {
        process?.write(MeetingCommand.reload)
    }

    /// The app quits.
    func shutdown() {
        cancelSpeech()
        stopDictating()
        process?.terminate()
        process = nil
        removeAttachment()
        removeSentImage()
    }

    // MARK: ⌃⌥T

    func hotKeyPressed() {
        if gesture.press(at: Date(), isOpen: isOpen) == .open { open() }
        holdTask?.cancel()
        holdTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(AskHotKeyGesture.holdThreshold))
            guard let self, !Task.isCancelled, self.gesture.holdElapsed(at: Date()) else { return }
            if !self.isOpen { self.open() }
            self.startListening()
        }
    }

    func hotKeyReleased() {
        holdTask?.cancel()
        switch gesture.release(at: Date()) {
        case .close: close()
        case .send: stopListening(andSend: true)
        case .nothing: break
        }
    }

    // MARK: Speaking

    /// The mic: Wispr Flow's hands-free dictation when Wispr Flow is installed, opened if it isn't
    /// running (a second press stops it and it pastes the words into the field), else Apple's
    /// recognizer. Holding ⌃⌥T always uses the recognizer.
    func toggleListening() {
        if isDictating { return stopDictating() }
        if isListening { return stopListening(andSend: true) }
        guard !isThinking else { return }
        if let wispr, wispr.isInstalled, !wisprDidntStart, !previewing {
            focusRequest += 1  // the field has the keyboard, so Wispr's paste lands there
            dictatingHere = true
            // Not running: the URL launches it first, which takes some seconds more.
            wispr.start(patience: wispr.isRunning ? 2.5 : 12)
        } else {
            startListening()
        }
    }

    private func stopDictating() {
        let wasDictating = isDictating
        dictatingHere = false
        guard wasDictating else { return }
        wispr?.stop()
        focusRequest += 1
    }

    /// Wispr Flow has no cancel: stopping it always pastes what it heard where the keyboard is. So
    /// the bubble keeps the keyboard until the words land in the field (or 2.5 s pass), then `done`.
    func finishDictation(then done: @escaping @MainActor () -> Void) {
        guard isDictating else { return done() }
        let before = text
        stopDictating()
        Task { [weak self] in
            let deadline = Date().addingTimeInterval(2.5)
            while Date() < deadline {
                guard let self, self.text == before else { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await Task.sleep(for: .milliseconds(150))  // the rest of the paste
            done()
        }
    }

    private func wisprChanged(_ phase: DictationModule.Phase) {
        guard dictatingHere else { return }
        switch phase {
        case .starting, .listening:
            break
        case .idle:
            dictatingHere = false  // it finished by itself and pastes
        case .sent, .unavailable:
            // The microphone never came up: no permission, signed out, or it didn't launch.
            dictatingHere = false
            wisprDidntStart = true
            setNotice(Localization.string("Wispr Flow didn't start, so Apple's recognizer listens"))
            startListening()
        }
    }

    private func setNotice(_ message: String?) {
        noticeReset?.cancel()
        withAnimation(Theme.snappy) { notice = message }
        guard message != nil else { return }
        noticeReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation(Theme.snappy) { self?.notice = nil }
        }
    }

    func startListening() {
        guard !isListening, !isThinking, !isDictating else { return }
        // Sample data never brings up a permission prompt (a recorded demo); speaking works if it's allowed.
        if AskSpeech.isDenied || (demo && !AskSpeech.isAuthorized) {
            fail("Tara needs speech recognition and the microphone: System Settings › Privacy & Security")
            return
        }
        listenWanted = true
        AskSpeech.authorize { [weak self] granted in
            // The keys let go while macOS asked: no listening without them.
            guard let self, self.isOpen, self.listenWanted else { return }
            self.listenWanted = false
            guard granted else {
                self.fail("Tara needs speech recognition and the microphone: System Settings › Privacy & Security")
                return
            }
            self.typedBeforeSpeaking = self.text.trimmingCharacters(in: .whitespaces)
            self.speechSession += 1
            let session = self.speechSession
            self.collectingSpeech = true
            self.sendAfterSpeech = false
            let started = self.speech.start(onText: { [weak self] words in
                guard let self, self.collectingSpeech, self.speechSession == session else { return }
                self.text = self.typedBeforeSpeaking.isEmpty ? words : self.typedBeforeSpeaking + " " + words
            }, onEnd: { [weak self] in
                // The final result (it came through onText just before) or an error.
                guard let self, self.speechSession == session else { return }
                if self.isListening {
                    self.speech.stop()
                    withAnimation(Theme.snappy) { self.phase = self.answer == nil ? .idle : .answered }
                }
                self.finishSpeech(session)
            })
            guard started else {
                self.collectingSpeech = false
                self.fail("Speech recognition isn't available for this language right now")
                return
            }
            Haptics.tick()
            withAnimation(Theme.snappy) { self.phase = .listening }
        }
    }

    func stopListening(andSend send: Bool) {
        listenWanted = false
        let wasListening = isListening
        speech.stop()
        if wasListening { withAnimation(Theme.snappy) { phase = answer == nil ? .idle : .answered } }
        guard send else { return }
        guard collectingSpeech else { return self.send() }
        // The last words and the recognizer's corrected text arrive a moment after the microphone
        // stops: the question goes with its final result, or after a short wait at most.
        sendAfterSpeech = true
        let session = speechSession
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            self?.finishSpeech(session)
        }
    }

    private func finishSpeech(_ session: Int) {
        guard session == speechSession, collectingSpeech else { return }
        collectingSpeech = false
        guard sendAfterSpeech else { return }
        sendAfterSpeech = false
        send()
    }

    private func cancelSpeech() {
        listenWanted = false
        collectingSpeech = false
        sendAfterSpeech = false
        speech.cancel()
    }

    // MARK: Asking

    func send() {
        // Return while speaking: the question goes once the last words are in.
        if isListening || collectingSpeech { return stopListening(andSend: true) }
        // Return while Wispr Flow dictates: it stops and pastes; the question goes with the next return.
        if isDictating { return stopDictating() }
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isThinking else { return }
        if previewing { return }
        guard startAgent(), let process else { return }
        willAsk()
        if keepsHistory {
            var failure: String?
            if case .failed(let message) = phase { failure = message }
            thread.archive(question: asked, answer: answer, failure: failure)
            showsChats = false
        }
        nextID += 1
        let id = "ask-\(nextID)"
        pending = id
        // Screen context may open an older day's file first (off the main thread): the question goes when it's there.
        let command = { [conversation, image = attachment?.url.path, document, scope] (screen: [ScreenAskItem]) in
            AskCommand.ask(question, conversation: conversation, image: image, document: document, scope: scope,
                           screen: screen, id: id)
        }
        if let screenContext {
            let day = scope?.day
            Task { [weak self] in
                let screen = await screenContext(question, day, self?.frontApp)
                guard self?.pending == id else { return }
                process.write(command(screen))
            }
        } else {
            process.write(command([]))
        }
        removeSentImage()
        sentImage = attachment?.url
        attachment = nil
        document = nil
        Haptics.confirm()
        withAnimation(Theme.snappy) {
            asked = question
            text = ""
            expanded = nil
            phase = .thinking(since: Date())
        }
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.patience)
            guard let self, !Task.isCancelled, self.pending == id else { return }
            self.pending = nil
            self.fail("Tara took too long to answer; see tara-ask.log in the app's folder")
        }
    }

    // MARK: Copy and save

    func copyAnswer() {
        guard let answer else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(answer.text, forType: .string)
        Haptics.tick()
        copied = true
        copiedReset?.cancel()
        copiedReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.copied = false
        }
    }

    /// The question and answer go to the notes: a line in the vault's inbox when a notes vault is
    /// connected, else a note of their own in the notepad. Once per answer.
    func saveAnswer() {
        guard let answer, saved == nil || saved == .failed else { return }
        let question = asked ?? answer.question
        let result: Saved
        if previewing {
            result = Self.savesToInbox ? .inbox : .notepad
        } else if Self.savesToInbox, let inbox = CaptureInbox.markdownFile {
            let capture = Capture(text: answer.inboxLine(asked: question, sourcesLabel: Localization.string("Sources")),
                                  route: .note)
            result = CaptureInbox.appendMarkdown(capture, to: inbox) ? .inbox : .failed
        } else if let notes, notes.add(answer.note(asked: question, sourcesLabel: Localization.string("Sources"))) {
            result = .notepad
        } else {
            result = .failed
        }
        result == .failed ? Haptics.tick() : Haptics.confirm()
        saved = result
    }

    /// A notes vault is connected and its inbox takes Markdown: saved answers go there.
    static var savesToInbox: Bool { Runtime.vault?.isConfigured == true && CaptureInbox.markdownFile != nil }

    private func resetActions() {
        copiedReset?.cancel()
        copied = false
        saved = nil
    }

    // MARK: Dropped on a window

    /// Tara let go over another app's window while the bubble is open: a picture of that window goes
    /// with the next question. Only then, so moving her around never takes pictures.
    func droppedOnWindow(at point: CGPoint) {
        guard isOpen, !isThinking, !capturing, !previewing, let target = AskWindowShot.window(at: point) else { return }
        // The rules and Apple's model can't see pictures; sample data never brings up the Screen Recording prompt.
        guard ![.rules, .apple].contains(MeetingAgentSetup.brain), !demo || CGPreflightScreenCaptureAccess() else { return }
        guard !ignores(target.bundleID) else {
            fail(String(format: Localization.string("%@ is on the ignore list in Settings › Tara's memory, so Tara doesn't look at it"), target.app))
            return
        }
        withAnimation(Theme.snappy) { capturing = true }
        let folder = Self.shotFolder
        Task { [weak self] in
            do {
                let url = try await AskWindowShot.capture(target, into: folder)
                guard let self, self.isOpen else {
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                self.removeAttachment()
                Haptics.confirm()
                withAnimation(Theme.snappy) {
                    self.capturing = false
                    self.attachment = Attachment(url: url, app: target.app)
                }
                self.focusRequest += 1
            } catch {
                guard let self else { return }
                withAnimation(Theme.snappy) { self.capturing = false }
                if case AskWindowShot.Failure.noPermission = error {
                    self.fail("Tara needs Screen Recording to see a window: System Settings › Privacy & Security › Screen Recording")
                } else {
                    self.fail("Couldn't take a picture of that window")
                }
            }
        }
    }

    func removeAttachment() {
        if let attachment { try? FileManager.default.removeItem(at: attachment.url) }
        withAnimation(Theme.snappy) { attachment = nil }
    }

    func removeDocument() {
        withAnimation(Theme.snappy) { document = nil }
    }

    /// A file dropped on Tara in the notch, to ask about: the bubble opens with it. A picture goes
    /// as a copy (the copy is deleted after the answer, never the file); a document goes as its
    /// text. The file itself is only read.
    func attach(file url: URL) {
        open()
        guard !isThinking, !previewing else { return }
        if TaraDocument.isImage(url) {
            guard ![.rules, .apple].contains(MeetingAgentSetup.brain) else {
                fail("Tara's brain can't see pictures; Settings › Tara's brain")
                return
            }
            let folder = Self.shotFolder
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appending(path: "drop-\(UUID().uuidString).\(url.pathExtension)")
            guard (try? FileManager.default.copyItem(at: url, to: copy)) != nil else {
                fail("Couldn't read that file")
                return
            }
            removeAttachment()
            withAnimation(Theme.snappy) { attachment = Attachment(url: copy, app: url.lastPathComponent) }
            tookFile()
            return
        }
        withAnimation(Theme.snappy) { capturing = true }
        Task { [weak self] in
            let text = await Task.detached(priority: .userInitiated) { TaraDocument.text(of: url) }.value
            guard let self, self.isOpen else { return }
            withAnimation(Theme.snappy) { self.capturing = false }
            guard let text else {
                self.fail("Tara can read PDFs, Word and text files; this one has no text she can read")
                return
            }
            withAnimation(Theme.snappy) { self.document = AskDocument(name: url.lastPathComponent, text: text) }
            self.tookFile()
        }
    }

    /// Tara took a file: a hop, a pleased face for a moment, a tick, and the keyboard in the field.
    private func tookFile() {
        Haptics.confirm()
        received += 1
        withAnimation(Theme.snappy) { justReceived = true }
        focusRequest += 1
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation(Theme.snappy) { self?.justReceived = false }
        }
    }

    /// A file dropped into the field arrives as its path (the text field takes it before anything
    /// else can): when what came in at once is the path of an existing file, it goes as the file.
    private func pickUpDroppedFile(after old: String) {
        guard text.count > old.count + 1, text.hasPrefix(old) else { return }
        var inserted = String(text.dropFirst(old.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        if inserted.hasPrefix("file://"), let url = URL(string: inserted) { inserted = url.path }
        var directory: ObjCBool = false
        guard inserted.hasPrefix("/"), !inserted.contains("\n"),
              FileManager.default.fileExists(atPath: inserted, isDirectory: &directory), !directory.boolValue else { return }
        text = old
        attach(file: URL(fileURLWithPath: inserted))
    }

    private func removeSentImage() {
        if let sentImage { try? FileManager.default.removeItem(at: sentImage) }
        sentImage = nil
    }

    /// A click on a source: a note or a capture opens where it lives, a meeting unfolds its quote.
    func openSource(_ source: AskSource) {
        Haptics.tick()
        if let url = source.url {
            NSWorkspace.shared.open(url)
        } else if source.kind == .capture, let file = CaptureInbox.markdownFile {
            CaptureInbox.openMarkdown(file)
        } else {
            withAnimation(Theme.snappy) { expanded = expanded == source.id ? nil : source.id }
        }
    }

    private func fail(_ message: String) {
        timeout?.cancel()
        removeSentImage()
        cancelSpeech()
        withAnimation(Theme.snappy) { phase = .failed(Localization.string(message)) }
    }

    // MARK: The agent

    /// Starts `agent.py` unless one runs with the current brain; false (with the reason shown) when it can't.
    private func startAgent() -> Bool {
        if process != nil, processBrain != MeetingAgentSetup.brain { endAgent() }  // the brain changed in Settings
        if process != nil { return true }
        let directory = Runtime.meetingAgentDir
        guard FileManager.default.fileExists(atPath: directory.appending(path: "agent.py").path) else {
            fail("Tara's agent isn't in this build; set [meeting] agent_dir in config.toml")
            return false
        }
        guard MeetingAgentSetup.uvPath != nil else {
            fail("Tara needs uv to think: Settings › Meeting agent › Install uv")
            return false
        }
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        generation += 1
        let current = generation
        offlineReason = nil  // a new agent says again whether Claude is reachable
        // Sample data: the demo meetings, as the meeting module's demo, and none of the user's own material.
        let command = (demo ? "exec uv run python agent.py --memory demo/meetings --today 2026-10-26 --captures '' --connectors ''"
                            : "exec uv run python agent.py") + TaraUsage.argument(folder: Brand.supportFolder)
        process = MeetingProcess(command: command, directory: directory, log: log, onLine: { [weak self] line in
            Task { @MainActor in self?.received(line) }
        }, onExit: { [weak self] in
            Task { @MainActor in self?.agentEnded(current) }
        })
        processBrain = MeetingAgentSetup.brain
        if process == nil { fail("Couldn't start Tara's agent") }
        return process != nil
    }

    private func endAgent() {
        guard let process else { return }
        self.process = nil
        process.closeInput()
        Task {
            try? await Task.sleep(for: .seconds(4))
            process.terminate()
        }
    }

    private func scheduleIdleEnd() {
        idleEnd?.cancel()
        idleEnd = Task { [weak self] in
            try? await Task.sleep(for: Self.idleLife)
            guard let self, !Task.isCancelled, !self.isOpen else { return }
            self.endAgent()
        }
    }

    private func received(_ line: Data) {
        guard line.first == UInt8(ascii: "{"), let reply = AskReply.parse(line) else { return }
        switch reply {
        case .ready:
            break
        case .offline(let why):
            offlineReason = why
        case .answer(let answer, let replyTo):
            guard replyTo != nil, replyTo == pending else { return }
            pending = nil
            timeout?.cancel()
            removeSentImage()
            if !answer.onRules { offlineReason = nil }  // Claude answered: it's reachable again
            conversation.append(question: answer.question, answer: answer.text)
            if keepsHistory {
                chat.turns.append(AskChat.Turn(question: asked ?? answer.question, answer: answer))
                Self.history.save(chat)
            }
            Haptics.tick()
            resetActions()
            withAnimation(Theme.snappy) {
                self.answer = answer
                phase = .answered
            }
        case .failed(let message, let replyTo):
            guard replyTo != nil, replyTo == pending else { return }
            pending = nil
            fail(message)
        }
    }

    private func agentEnded(_ ended: Int) {
        guard ended == generation, process != nil else { return }
        process = nil
        if pending != nil {
            pending = nil
            fail("Tara's agent stopped; see tara-ask.log in the app's folder")
        }
    }

    // MARK: Previews

    /// Long enough to scroll in the answer card.
    private static let longAnswer = """
        Beim Preis habt ihr euch auf 30 Euro im Monat festgelegt. Im Kickoff am 12. Oktober lagen zwei Vorschläge auf dem Tisch: 25 Euro, um schneller Nutzer zu gewinnen, und 30 Euro, weil die Kosten pro Nutzer sonst kaum gedeckt wären. Jonas hat sich für 30 Euro ausgesprochen, und niemand hat widersprochen.

        Im Weekly eine Woche später kam das Thema noch einmal auf, weil Max einen Rabatt für Jahresabos vorgeschlagen hat. Der Rabatt ist noch offen: Max rechnet bis Freitag durch, was zwei Monate gratis im Jahresabo kosten würden. Am Monatspreis ändert das nichts, die 30 Euro bleiben.

        Offen ist außerdem, ob es einen günstigeren Tarif für Studierende gibt. Das wurde nur kurz erwähnt und auf die Zeit nach dem Launch verschoben. Für die Launch-Seite heißt das: ein Preis, 30 Euro im Monat, und der Hinweis auf das Jahresabo erst, wenn Max' Rechnung steht.

        Nächster Schritt laut deinen Notizen: Preis mit Max klären, bevor die Seite live geht.
        """

    /// `--preview ask-empty | ask-typed | ask-listening | ask-thinking | ask-answer | ask-long | ask-rules | ask-window | ask-failed | ask-thread | ask-chats`
    /// show made-up states.
    /// `ask-send:<question>` is live: the real agent and brain answer it from the demo meetings (for
    /// recordings and checks).
    func preview(_ name: String) {
        if name.hasPrefix("ask-send:") {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(700))
                self?.open()
                self?.text = String(name.dropFirst("ask-send:".count))
                self?.send()
            }
            return
        }
        previewing = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self else { return }
            self.open()
            let question = "Was haben wir beim Preis entschieden?"
            switch name {
            case "ask-typed":
                self.text = question
            case "ask-listening":
                self.text = "Was haben wir beim Preis"
                self.phase = .listening
            case "ask-thinking":
                self.asked = question
                self.phase = .thinking(since: Date().addingTimeInterval(-4))
            case "ask-answer":
                self.asked = question
                self.answer = AskAnswer(question: question, text: "30 Euro im Monat. Im Kickoff wurden 25 Euro verworfen, im Weekly hat Jonas die 30 bestätigt.", sources: [
                    AskSource(id: "0", kind: .meeting, title: "Kickoff Lumen-Abo", quote: "Okay, dann entscheiden wir: Das Lumen-Abo kostet 30 Euro im Monat.", speaker: "Jonas", date: "2026-10-12"),
                    AskSource(id: "1", kind: .meeting, title: "Weekly Lumen-Abo", quote: "Und wir bleiben beim Preis von 30 Euro.", speaker: "Jonas", date: "2026-10-19"),
                    AskSource(id: "2", kind: .note, title: "Pricing", quote: "", date: "2026-10-20", url: URL(string: "file:///tmp/Pricing.md")),
                ], brain: "claude-code")
                self.expanded = "0"
                self.phase = .answered
            case "ask-long":
                self.asked = question
                self.answer = AskAnswer(question: question, text: Self.longAnswer, sources: [
                    AskSource(id: "0", kind: .meeting, title: "Kickoff Lumen-Abo", quote: "Das Lumen-Abo kostet 30 Euro im Monat.", speaker: "Jonas", date: "2026-10-12"),
                    AskSource(id: "1", kind: .capture, title: "Preis mit Max klären", quote: "Preis mit Max klären", date: "2026-10-24"),
                ], brain: "claude-code")
                self.phase = .answered
            case "ask-rules":
                self.asked = "Wie wird das Wetter morgen?"
                self.answer = AskAnswer(question: "Wie wird das Wetter morgen?",
                                        text: "Ohne Claude finde ich nur Wörter in deinen Meetings und Notizen, und dazu steht dort nichts. Verbinde Claude Code in den Einstellungen, dann beantworte ich auch richtige Fragen.",
                                        brain: "rules")
                self.phase = .answered
            case "ask-window":
                self.text = "Was ist an diesem Diff riskant?"
                self.attachment = Attachment(url: URL(fileURLWithPath: "/tmp/none.jpg"), app: "Safari")
            case "ask-thread":
                // A follow-up: the first question and its answer above the one on screen (in English, for the README).
                let first = "What did we decide on the price?"
                self.thread.archive(question: first, answer: AskAnswer(question: first,
                    text: "30 euros a month. The kickoff dropped 25; in the weekly, Jonas confirmed 30.",
                    brain: "claude-code"), failure: nil)
                let follow = "And the discount for yearly plans?"
                self.asked = follow
                self.answer = AskAnswer(question: follow, text: "Still open: Max is working out by Friday what two free months on a yearly plan would cost.", sources: [
                    AskSource(id: "0", kind: .meeting, title: "Weekly · Lumen plan", quote: "I'll work that out by Friday.", speaker: "Max", date: "2026-10-19"),
                ], brain: "claude-code")
                self.phase = .answered
            case "ask-chats":
                let day: TimeInterval = 86_400
                self.chats = [
                    AskChat(started: Date().addingTimeInterval(-3_600), turns: [AskChat.Turn(question: question, answer: AskAnswer(question: question, text: "30 Euro."))]),
                    AskChat(started: Date().addingTimeInterval(-day), turns: [
                        AskChat.Turn(question: "Wer hat die Launch-Checkliste?", answer: AskAnswer(question: "", text: "Lena.")),
                        AskChat.Turn(question: "Bis wann?", answer: AskAnswer(question: "", text: "Bis Freitag.")),
                    ]),
                    AskChat(started: Date().addingTimeInterval(-4 * day), turns: [AskChat.Turn(question: "Was hat Max zum Budget gesagt?", answer: AskAnswer(question: "", text: "…"))]),
                ]
                self.showsChats = true
            case "ask-failed":
                self.asked = question
                self.phase = .failed(Localization.string("Tara needs uv to think: Settings › Meeting agent › Install uv"))
            default:
                break
            }
        }
    }
}
