import AppKit
import NotchCore
import Observation
import SwiftUI

/// The teleprompter: a script read from a band hanging from the notch, close to the camera, so the
/// eyes stay near the lens. The text follows the voice (`PrompterListener`, `PrompterFollower`) or
/// moves at a constant speed. The band is part of the island, which stays out of screen sharing.
///
/// A session lasts from opening to closing; another island (the palette, the panel) may cover the
/// band meanwhile, which pauses it until it shows again. Recent scripts are kept in the support
/// folder (`PrompterLibrary`); previews keep everything in memory.
@MainActor
@Observable
final class Prompter {
    enum Phase: Equatable {
        /// Choosing a script: paste, drop, or a recent one.
        case setup
        case reading
    }

    private(set) var isOpen = false
    private(set) var phase = Phase.setup
    private(set) var script: PrompterScript?
    private(set) var text = PrompterText("")
    private(set) var scripts: [PrompterScript] = []
    /// The recent script under the keyboard in the setup (↑↓, ↵).
    var selected = 0
    var settings: PrompterSettings {
        didSet {
            guard settings != oldValue else { return }
            if persists, let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: Self.settingsKey) }
            if settings.textSize != oldValue.textSize { relayout() }
        }
    }
    /// The next word to read; those before it show as read.
    private(set) var word = 0
    /// Stopped with space (or before a constant-speed start); listening is off meanwhile.
    private(set) var paused = false
    private(set) var listening = PrompterListener.State.idle
    /// Words came in during the last moment: the listening mark moves.
    private(set) var hearing = false
    /// One line about something that went wrong or needs the user.
    private(set) var notice: String?
    /// A file is dragged over the band.
    var dropTargeted = false

    /// The script in lines for the band's width.
    private(set) var layout = PrompterLayout(widths: [], paragraphs: [], space: 0, width: 0, lineHeight: 30, paragraphGap: 0)
    /// The top of the line being read, in points from the first line; at constant speed, where
    /// the text stood when it started moving (`rollingSince`).
    private(set) var scroll: CGFloat = 0
    private(set) var rollingSince: Date?

    @ObservationIgnored private var textWidth: CGFloat = 0
    @ObservationIgnored private var follower: PrompterFollower?
    @ObservationIgnored private let listener = PrompterListener()
    @ObservationIgnored private let library: PrompterLibrary?
    @ObservationIgnored private let persists: Bool
    @ObservationIgnored private var resumeWhenShown = false
    @ObservationIgnored private var hearingTask: Task<Void, Never>?
    @ObservationIgnored private var endTask: Task<Void, Never>?
    @ObservationIgnored private var lastMove = Date()
    @ObservationIgnored private var updatesSinceMove = 0
    @ObservationIgnored private var scrollRest: CGFloat = 0

    static let settingsKey = "prompterSettings"
    static let scriptsFile = "prompter-scripts.json"
    /// Files larger than this aren't read: a script, not a book.
    static let maxFileSize = 1_000_000
    static let fileTypes: Set<String> = ["txt", "text", "md", "markdown"]

    /// `library` nil keeps the recent scripts in memory (previews, sample data).
    init(library: PrompterLibrary?, persists: Bool) {
        self.library = library
        self.persists = persists
        let stored = persists ? UserDefaults.standard.data(forKey: Self.settingsKey) : nil
        settings = stored.flatMap { try? JSONDecoder().decode(PrompterSettings.self, from: $0) } ?? PrompterSettings()
        listener.onHeard = { [weak self] transcript, session in self?.heard(transcript, session: session) }
        listener.onState = { [weak self] state in self?.listenerChanged(state) }
    }

    // MARK: Session

    /// Opens on the setup: paste, drop or pick a recent script.
    func open() {
        scripts = library?.load() ?? scripts
        selected = 0
        notice = nil
        isOpen = true
        phase = .setup
    }

    /// Ends the session: listening stops, the place is kept for next time.
    func close() {
        stopMoving()
        listener.stop()
        keepPlace()
        isOpen = false
        resumeWhenShown = false
        dropTargeted = false
        phase = .setup
        script = nil
    }

    /// Another island covers the band: pause, and pick up again once it shows.
    func covered() {
        guard isOpen, phase == .reading, !paused else { return }
        resumeWhenShown = true
        setPaused(true)
    }

    func shown() {
        guard isOpen, resumeWhenShown else { return }
        resumeWhenShown = false
        setPaused(false)
    }

    /// Reads `script` from where it stopped last time (from the start when it was read to the end).
    func read(_ script: PrompterScript) {
        stopMoving()
        listener.stop()
        var script = script
        script.used = Date()
        self.script = script
        remember(script)
        text = PrompterText(script.text)
        let start = script.word < text.words.count ? max(0, script.word) : 0
        follower = PrompterFollower(keys: text.keys, language: script.spokenLanguage, position: text.key(atWord: start))
        word = start
        notice = nil
        phase = .reading
        relayout()
        scroll = top(ofWord: start)
        // At constant speed the text waits for space; the voice starts following at once.
        paused = settings.mode == .constant
        if !paused { startFollowing() }
    }

    /// The recent scripts, for the palette.
    func recent() -> [PrompterScript] {
        library?.load() ?? scripts
    }

    /// Back to the setup from reading (the scripts button); esc returns.
    func showScripts() {
        guard phase == .reading else { return }
        Haptics.tick()
        setPaused(true)
        keepPlace()
        scripts = library?.load() ?? scripts
        selected = 0
        phase = .setup
    }

    /// Esc in the setup with a script loaded: back to it. False when there is none.
    func backToReading() -> Bool {
        guard phase == .setup, script != nil else { return false }
        Haptics.tick()
        phase = .reading
        setPaused(false)
        return true
    }

    // MARK: Scripts in

    func paste() {
        Haptics.tick()
        guard let string = NSPasteboard.general.string(forType: .string),
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            notice = Localization.string("The clipboard has no text")
            return
        }
        load(string, title: nil)
    }

    /// A file dropped on the band (or on the notch): a .txt or .md file, read and never changed.
    func drop(_ url: URL) {
        dropTargeted = false
        guard Self.fileTypes.contains(url.pathExtension.lowercased()) else {
            notice = Localization.string("Drop a .txt or .md file")
            return
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= Self.maxFileSize else {
            notice = Localization.string("That file is too long for the teleprompter")
            return
        }
        guard let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .windowsCP1252)),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            notice = Localization.string("Couldn't read that file")
            return
        }
        Haptics.confirm()
        let markdown = ["md", "markdown"].contains(url.pathExtension.lowercased())
        load(markdown ? PrompterText.plain(markdown: raw) : raw, title: url.deletingPathExtension().lastPathComponent)
    }

    private func load(_ string: String, title: String?) {
        if phase == .reading { keepPlace() }
        read(PrompterLibrary.script(for: string, title: title, in: scripts))
    }

    func delete(_ script: PrompterScript) {
        Haptics.tick()
        withAnimation(Theme.snappy) {
            scripts = library?.delete(script.id) ?? scripts.filter { $0.id != script.id }
            selected = min(selected, max(0, scripts.count - 1))
        }
        if self.script?.id == script.id { self.script = nil }
    }

    private func remember(_ script: PrompterScript) {
        scripts = library?.save(script) ?? PrompterLibrary.keeping(script, in: scripts)
    }

    /// The place reached, saved with the script for next time.
    private func keepPlace() {
        guard var script, phase == .reading else { return }
        script.word = word
        script.used = Date()
        self.script = script
        remember(script)
    }

    // MARK: Following

    /// Space: pause or go on.
    func togglePause() {
        guard phase == .reading else { return }
        Haptics.tick()
        resumeWhenShown = false
        setPaused(!paused)
    }

    private func setPaused(_ pause: Bool) {
        if pause {
            stopMoving()
            listener.stop()
            paused = true
        } else {
            paused = false
            if word >= text.words.count, !text.words.isEmpty { moveTo(word: 0, animated: false) }
            notice = nil
            startFollowing()
        }
    }

    private func startFollowing() {
        guard phase == .reading else { return }
        switch settings.mode {
        case .voice:
            lastMove = Date()
            updatesSinceMove = 0
            listener.start(language: script?.spokenLanguage ?? .en, hints: Self.hints(text))
        case .constant:
            rollingSince = Date()
            scheduleEnd()
        }
    }

    /// Follow the voice, or move at a constant speed.
    func setMode(_ mode: PrompterSettings.Mode) {
        guard mode != settings.mode else { return }
        Haptics.tick()
        let wasPaused = paused
        if phase == .reading { setPaused(true) }
        settings.mode = mode
        notice = nil
        guard phase == .reading else { return }
        follower?.jump(to: text.key(atWord: word))
        moveTo(word: word, animated: true)  // constant speed may have stopped mid-line
        if !wasPaused { setPaused(false) }
    }

    /// The script's language for listening: German or English.
    func toggleLanguage() {
        guard var script else { return }
        Haptics.tick()
        script.language = script.spokenLanguage == .de ? .en : .de
        self.script = script
        remember(script)
        follower = PrompterFollower(keys: text.keys, language: script.spokenLanguage, position: follower?.position ?? 0)
        notice = nil
        if settings.mode == .voice, !paused { startFollowing() }
    }

    func stepSpeed(_ direction: Int) {
        Haptics.tick()
        let now = Date()
        if rollingSince != nil {
            scroll = rolledScroll(at: now)
            rollingSince = now
        }
        settings.stepSpeed(direction)
        scheduleEnd()
    }

    func stepTextSize(_ direction: Int) {
        Haptics.tick()
        withAnimation(Theme.snappy) { settings.stepTextSize(direction) }
    }

    func stepLines(_ direction: Int) {
        Haptics.tick()
        withAnimation(Theme.snappy) { settings.stepLines(direction) }
    }

    /// ↑↓ or scrolling: a line back or on; following goes on from there.
    func step(_ lines: Int) {
        guard phase == .reading, !layout.lines.isEmpty else { return }
        let now = Date()
        let line = currentLine(at: now)
        let target = min(max(0, line + lines), layout.lines.count - 1)
        guard target != line else { return }
        Haptics.tick()
        let start = layout.lines[target].words.lowerBound
        follower?.jump(to: text.key(atWord: start))
        if rollingSince != nil { rollingSince = now }
        moveTo(word: start, animated: true)
        scheduleEnd()
        notice = nil
    }

    /// Scroll wheel or trackpad over the band: a line per notch of the wheel, or per line's height
    /// of a trackpad swipe (no momentum, so it stops where the fingers do).
    func scrolled(by delta: CGFloat, precise: Bool) {
        guard phase == .reading else { return }
        scrollRest += delta
        // A wheel reports lines, a trackpad points.
        let threshold = precise ? layout.lineHeight * 0.6 : 1
        while abs(scrollRest) >= threshold {
            step(scrollRest > 0 ? -1 : 1)
            scrollRest -= scrollRest > 0 ? threshold : -threshold
        }
    }

    private func heard(_ transcript: String, session: Int) {
        guard phase == .reading, settings.mode == .voice, !paused, follower != nil else { return }
        showHearing()
        guard follower?.hear(transcript, session: session) == true, let follower else {
            updatesSinceMove += 1
            // Lots heard, nothing found: likely the wrong language, or off the script entirely.
            if updatesSinceMove > 40, Date().timeIntervalSince(lastMove) > 12, notice == nil {
                notice = Localization.string("Not finding your place? Check the language, or move with ↓")
            }
            return
        }
        lastMove = Date()
        updatesSinceMove = 0
        if notice != nil { notice = nil }
        moveTo(word: text.word(atKey: follower.position), animated: true)
        if follower.isFinished {
            listener.stop()
            paused = true
        }
    }

    private func showHearing() {
        if !hearing { hearing = true }
        hearingTask?.cancel()
        hearingTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            self?.hearing = false
        }
    }

    private func listenerChanged(_ state: PrompterListener.State) {
        listening = state
        guard case .unavailable(let problem) = state, phase == .reading else { return }
        // Can't listen: constant speed, waiting for space, and one line saying why.
        settings.mode = .constant
        paused = true
        let reason = switch problem {
        case .denied: Localization.string("The microphone or speech recognition is off for this app in System Settings")
        case .language: script?.spokenLanguage == .de
            ? Localization.string("No on-device recognition for German on this Mac")
            : Localization.string("No on-device recognition for English on this Mac")
        case .microphone: Localization.string("No microphone found")
        case .failed: Localization.string("Listening stopped")
        }
        notice = reason + " · " + Localization.string("constant speed, space to start")
    }

    /// The script's rarer words for the recognizer (names, long words): those get misheard most.
    static func hints(_ text: PrompterText) -> [String] {
        var seen = Set<String>()
        var hints: [String] = []
        for word in text.words where !word.cue {
            let clean = word.text.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            guard clean.count >= 7 || (clean.first?.isUppercase == true && clean.count >= 4),
                  clean.allSatisfy({ $0.isLetter || $0 == "-" }), seen.insert(clean.lowercased()).inserted else { continue }
            hints.append(clean)
            if hints.count == 100 { break }
        }
        return hints
    }

    // MARK: Position and motion

    /// Line height for the type size: a little open, for reading at a glance.
    var lineHeight: CGFloat { (CGFloat(settings.textSize) * 1.32).rounded() }

    /// Room between paragraphs.
    var paragraphGap: CGFloat { (lineHeight * 0.4).rounded() }

    /// The reading area: the lines, plus one paragraph's gap so a paragraph break doesn't cut the last line.
    var visibleHeight: CGFloat { CGFloat(settings.lines) * lineHeight + paragraphGap }

    /// The band's height under the notch row.
    var bodyHeight: CGFloat {
        switch phase {
        case .reading: Self.readingTop + visibleHeight + Self.readingBottom
        case .setup: PrompterSetup.height(rows: scripts.count)
        }
    }

    static let readingTop: CGFloat = 6
    static let readingBottom: CGFloat = 12
    /// Text inset from the island's sides.
    static let sideInset: CGFloat = 26

    /// The line being read sits second from the top, below one read line for orientation; with
    /// three lines it sits on top, so two are still ahead.
    var anchorLine: Int { settings.lines >= 4 ? 1 : 0 }

    /// The band's width, for the lines (the island fits itself between menu bar icons).
    func fit(width: CGFloat) {
        let available = max(0, width - 2 * Self.sideInset)
        guard abs(available - textWidth) > 0.5 else { return }
        textWidth = available
        relayout()
    }

    private func relayout() {
        guard textWidth > 0 else { return }
        // Keep reading on the same word at the new size.
        let now = Date()
        let reading = word(at: now)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: CGFloat(settings.textSize), weight: .medium)]
        var widths: [String: CGFloat] = [:]
        let measured = text.words.map { word in
            if let width = widths[word.text] { return width }
            let width = ceil((word.text as NSString).size(withAttributes: attributes).width)
            widths[word.text] = width
            return width
        }
        let space = (" " as NSString).size(withAttributes: attributes).width
        // A little slack, so a line never runs past the edge where SwiftUI sets type a hair wider.
        layout = PrompterLayout(widths: measured, paragraphs: text.words.map(\.paragraph), space: space,
                                width: textWidth - 6, lineHeight: lineHeight, paragraphGap: paragraphGap)
        scroll = top(ofWord: reading)
        if rollingSince != nil {
            rollingSince = now
            scheduleEnd()
        }
    }

    private func top(ofWord word: Int) -> CGFloat {
        layout.lines.isEmpty ? 0 : layout.lines[layout.line(ofWord: word)].top
    }

    /// Where the text stands at `date`: moving at constant speed, else where reading is.
    func rolledScroll(at date: Date) -> CGFloat {
        guard let since = rollingSince else { return scroll }
        let end = layout.lines.last?.top ?? 0
        let speed = layout.pointsPerSecond(wordsPerMinute: settings.wordsPerMinute)
        return min(end, scroll + speed * CGFloat(max(0, date.timeIntervalSince(since))))
    }

    /// The line being read at `date`.
    func currentLine(at date: Date) -> Int {
        rollingSince == nil ? layout.line(ofWord: word) : layout.line(atY: rolledScroll(at: date))
    }

    /// The next word to read at `date`: at constant speed, as far along the line as the text has moved.
    func word(at date: Date) -> Int {
        guard rollingSince != nil, !layout.lines.isEmpty else { return word }
        let y = rolledScroll(at: date)
        let line = layout.lines[layout.line(atY: y)]
        let progress = min(1, max(0, (y - line.top) / max(1, layout.lineHeight)))
        return line.words.lowerBound + Int((CGFloat(line.words.count) * progress).rounded(.down))
    }

    /// Constant speed stops: the text stays where it got to, reading goes on from that word.
    private func stopMoving() {
        endTask?.cancel()
        guard rollingSince != nil else { return }
        let now = Date()
        let reached = word(at: now)
        scroll = rolledScroll(at: now)
        rollingSince = nil
        word = reached
        follower?.jump(to: text.key(atWord: reached))
    }

    /// At constant speed: stops on the last line instead of running on into nothing.
    private func scheduleEnd() {
        endTask?.cancel()
        guard let since = rollingSince else { return }
        let speed = layout.pointsPerSecond(wordsPerMinute: settings.wordsPerMinute)
        guard speed > 0 else { return }
        let seconds = max(0, Double(((layout.lines.last?.top ?? 0) - scroll) / speed))
        endTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds + 0.05))
            guard let self, !Task.isCancelled, self.rollingSince == since else { return }
            self.stopMoving()
            self.paused = true
        }
    }

    /// Moves reading to `word`; the text slides to its line. A jump of more than a few lines cuts
    /// instead of sliding past text nobody reads, and so does Reduce Motion.
    private func moveTo(word: Int, animated: Bool) {
        let target = top(ofWord: word)
        let distance = abs(layout.line(ofWord: word) - layout.line(ofWord: self.word))
        self.word = word
        guard rollingSince == nil else {
            scroll = target
            return
        }
        guard target != scroll else { return }
        if animated, !Theme.reduceMotion, distance <= 4 {
            withAnimation(.smooth(duration: 0.45)) { scroll = target }
        } else {
            scroll = target
        }
    }

    // MARK: Keys

    /// The band's keys while it has the keyboard; esc belongs to the island (`NotchController`).
    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        switch phase {
        case .setup:
            switch event.keyCode {
            case 9 where command: paste()                                   // ⌘V
            case 125 where !scripts.isEmpty: Haptics.tick(); selected = min(selected + 1, scripts.count - 1)
            case 126 where !scripts.isEmpty: Haptics.tick(); selected = max(selected - 1, 0)
            case 36, 76:
                guard scripts.indices.contains(selected) else { return false }
                Haptics.confirm()
                read(scripts[selected])
            default: return false
            }
            return true
        case .reading:
            switch event.keyCode {
            case 126: step(-1)                                              // ↑
            case 125: step(1)                                               // ↓
            case 49: togglePause()                                          // space
            case 123 where settings.mode == .constant: stepSpeed(-1)        // ←
            case 124 where settings.mode == .constant: stepSpeed(1)         // →
            case 24 where command: stepTextSize(1)                          // ⌘+
            case 27 where command: stepTextSize(-1)                         // ⌘−
            case 9 where command: paste()                                   // ⌘V: another script
            default: return false
            }
            return true
        }
    }

    // MARK: Previews

    /// Previews: made-up recent scripts, and `script` open at `word` (simulated progress, no microphone).
    func preview(scripts: [PrompterScript], reading script: PrompterScript?, word: Int, mode: PrompterSettings.Mode = .voice) {
        self.scripts = scripts
        isOpen = true
        phase = .setup
        settings.mode = mode
        guard let script else { return }
        self.script = script
        text = PrompterText(script.text)
        follower = PrompterFollower(keys: text.keys, language: script.spokenLanguage, position: text.key(atWord: word))
        phase = .reading
        relayout()
        self.word = word
        scroll = top(ofWord: word)
        paused = mode == .constant
        listening = mode == .voice ? .listening : .idle
        hearing = mode == .voice
    }

    /// Previews: the speaker reads on by `words`.
    func previewAdvance(_ words: Int) {
        moveTo(word: min(text.words.count, word + words), animated: true)
    }
}
