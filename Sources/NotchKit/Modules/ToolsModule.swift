import AppKit
import ImageIO
import NotchCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// The small tools: clipboard history, a focus timer, and a shelf for files (drag in, drag out,
/// AirDrop, convert images). The clipboard is watched every half second, kept in memory only,
/// and never takes copies marked secret or made in a password app.
@MainActor
@Observable
final class ToolsModule: NotchModule {
    enum Tab: String, CaseIterable {
        case clipboard = "Clipboard", timer = "Timer", shelf = "Shelf"
        case notes = "Notes"

        var symbol: String {
            switch self {
            case .clipboard: "doc.on.clipboard"
            case .timer: "timer"
            case .shelf: "tray.and.arrow.down"
            case .notes: "note.text"
            }
        }
    }

    /// The timer card's three kinds.
    enum TimerKind: String, CaseIterable { case pomodoro = "Pomodoro", countdown = "Timer", stopwatch = "Stopwatch" }

    let kind = ModuleKind.tools
    let symbol = ModuleSymbols.symbol(.tools)

    var tab = Tab.clipboard
    /// The tabs switched on in Settings › Tools, in their order.
    var tabs = Tab.allCases {
        didSet { if !tabs.contains(tab), let first = tabs.first { tab = first } }
    }
    /// The image converter is switched on (it works on the shelf's files).
    var converts = true
    /// Quick notes (the daily tools' store), set by the app.
    var notes: NotesStore?
    private(set) var history = ClipboardHistory()
    private(set) var timer = FocusTimer()
    /// Countdown and stopwatch.
    private(set) var simple = SimpleTimer()
    var timerKind = TimerKind.pomodoro
    private(set) var shelf: [URL] = []
    /// The row under the keyboard in the clipboard list.
    var selected: UUID?
    /// One line after an action ("Copied", "Converted to PNG").
    private(set) var note: String?

    /// A focus or break ended: the app shows a sneak.
    @ObservationIgnored var onPhaseEnd: ((FocusTimer.Phase, FocusTimer.Phase) -> Void)?
    /// A countdown reached zero.
    @ObservationIgnored var onCountdownDone: ((TimeInterval) -> Void)?
    /// Watch the clipboard only while the module is switched on.
    @ObservationIgnored var isEnabled: () -> Bool = { true }
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var lastChange = NSPasteboard.general.changeCount
    @ObservationIgnored private var noteTask: Task<Void, Never>?

    func start() {
        guard watcher == nil else { return }
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                self?.readClipboard()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    // MARK: Clipboard

    private func readClipboard() {
        let board = NSPasteboard.general
        guard board.changeCount != lastChange else { return }
        lastChange = board.changeCount
        guard isEnabled() else { return }
        let types = board.types?.map(\.rawValue) ?? []
        let front = NSWorkspace.shared.frontmostApplication
        guard !ClipboardHistory.shouldSkip(types: types, app: front?.bundleIdentifier),
              let text = board.string(forType: .string) else { return }
        withAnimation(Theme.snappy) { _ = history.add(text, source: front?.localizedName, at: Date()) }
    }

    /// Puts an item back on the clipboard (it moves to the top), ready to paste.
    func copy(_ item: ClipItem) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(item.text, forType: .string)
        lastChange = board.changeCount
        Haptics.confirm()
        withAnimation(Theme.snappy) { _ = history.add(item.text, source: item.source, at: Date()) }
        show("Copied. Paste with ⌘V")
    }

    func togglePin(_ item: ClipItem) {
        Haptics.tick()
        withAnimation(Theme.snappy) { history.togglePin(item.id) }
    }

    func remove(_ item: ClipItem) {
        withAnimation(Theme.snappy) { history.remove(item.id) }
    }

    func clearHistory() {
        withAnimation(Theme.snappy) { history.clear() }
    }

    // MARK: Timer

    func startOrPause() {
        let now = Date()
        Haptics.tick()
        switch timerKind {
        case .pomodoro:
            if timer.isRunning { timer.pause(at: now) } else { timer.start(at: now) }
        case .countdown, .stopwatch:
            simple.mode = timerKind == .stopwatch ? .stopwatch : .countdown
            if simple.isRunning { simple.pause(at: now) } else { simple.start(at: now) }
        }
        runTicker()
    }

    /// Countdown length, while it isn't running.
    func setCountdown(minutes: Double) {
        guard !simple.isActive else { return }
        Haptics.tick()
        simple.duration = max(60, min(24 * 3600, minutes * 60))
    }

    /// Pomodoro lengths, while no round runs.
    func setPomodoro(focus: Double? = nil, pause: Double? = nil) {
        guard timer.phase == .idle else { return }
        Haptics.tick()
        if let focus { timer.focusMinutes = focus }
        if let pause { timer.breakMinutes = pause }
    }

    func resetSimple() {
        Haptics.tick()
        simple.reset()
        runTicker()
    }

    /// A timer of any kind is going (or paused): it sits beside the notch.
    var timerActive: Bool { timer.isRunning || timer.isPaused || simple.isActive }

    /// The running timer's face: kind, time shown, paused.
    func face(at now: Date) -> (symbol: String, tint: Color, time: TimeInterval, paused: Bool)? {
        if timer.isRunning || timer.isPaused {
            let focus = timer.phase == .focus
            return (focus ? "timer" : "cup.and.saucer.fill", focus ? Theme.accent : Theme.ok, timer.remaining(at: now), timer.isPaused)
        }
        if simple.isActive {
            return (simple.mode == .stopwatch ? "stopwatch" : "hourglass", Theme.waiting, simple.shown(at: now), !simple.isRunning)
        }
        return nil
    }

    func skipPhase() {
        Haptics.tick()
        timer.skip(at: Date())
        runTicker()
    }

    func stopTimer() {
        Haptics.tick()
        timer.stop()
        ticker?.cancel()
        ticker = nil
    }

    /// Once a second while a phase runs; nothing while idle or paused.
    private func runTicker() {
        ticker?.cancel()
        guard timer.isRunning || (simple.isRunning && simple.mode == .countdown) else { ticker = nil; return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                let now = Date()
                if let ended = self.timer.tick(at: now) { self.onPhaseEnd?(ended, self.timer.phase) }
                let length = self.simple.duration
                if self.simple.tick(at: now) { self.onCountdownDone?(length) }
                if !self.timer.isRunning && !(self.simple.isRunning && self.simple.mode == .countdown) { return }
            }
        }
    }

    // MARK: Shelf

    func add(_ urls: [URL]) {
        let new = urls.filter { url in !shelf.contains(url) }
        guard !new.isEmpty else { return }
        Haptics.confirm()
        withAnimation(Theme.snappy) { shelf.insert(contentsOf: new, at: 0) }
    }

    func removeFromShelf(_ url: URL) {
        withAnimation(Theme.snappy) { shelf.removeAll { $0 == url } }
    }

    func clearShelf() {
        withAnimation(Theme.snappy) { shelf.removeAll() }
    }

    func airDrop(_ urls: [URL]) {
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls)
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// A copy of the image in another format, next to the original; it joins the shelf.
    func convert(_ url: URL, to format: ImageFormat) {
        do {
            let output = try ImageConverter.convert(url, to: format)
            add([output])
            show("Saved \(output.lastPathComponent)")
        } catch {
            show("Couldn't convert \(url.lastPathComponent)")
        }
    }

    private func show(_ text: String) {
        withAnimation(Theme.snappy) { note = text }
        noteTask?.cancel()
        noteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            withAnimation(Theme.snappy) { self?.note = nil }
        }
    }

    // MARK: NotchModule

    var count: Int? { timerActive ? nil : (shelf.isEmpty ? nil : shelf.count) }

    /// A running timer sits beside the notch, also at rest: the user started it to see it.
    var ambientPriority: Int { timerActive ? 25 : 0 }
    var needsAttention: Bool { timerActive }

    func leadingEar(peek: Bool) -> AnyView {
        AnyView(TimelineView(.periodic(from: .now, by: 1)) { context in
            if let face = self.face(at: context.date) {
                Image(systemName: face.symbol)
                    .font(.system(size: peek ? 12 : 11, weight: .semibold))
                    .foregroundStyle(face.tint)
            }
        })
    }

    func trailingEar(peek: Bool) -> AnyView {
        AnyView(TimelineView(.periodic(from: .now, by: 1)) { context in
            if let face = self.face(at: context.date) {
                Text(Countdown.text(face.time))
                    .font(Theme.font(peek ? 12.5 : 11, .semibold).monospacedDigit())
                    .foregroundStyle(face.paused ? Theme.textSecondary : Theme.textBody)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .fixedSize()
            }
        })
    }

    func peekLine() -> AnyView {
        AnyView(TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                if let face = self.face(at: context.date) {
                    Text(self.timer.isRunning || self.timer.isPaused ? self.timer.phase.title
                         : self.simple.mode == .stopwatch ? "Stopwatch" : "Timer")
                        .font(Theme.font(13, .semibold)).foregroundStyle(Theme.textPrimary)
                    Text(Countdown.text(face.time) + (face.paused ? " · paused" : ""))
                        .font(Theme.font(12.5).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                } else if let last = self.history.list().first {
                    Image(systemName: "doc.on.clipboard").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    Text(last.line(60)).font(Theme.font(12.5)).foregroundStyle(Theme.textBody)
                } else {
                    Text("Clipboard, timer and shelf").font(Theme.font(13, .medium)).foregroundStyle(Theme.textBody)
                }
                Spacer(minLength: 0)
            }
            .lineLimit(1)
        })
    }

    func body() -> AnyView { AnyView(ToolsBody(module: self)) }

    func primaryAction() {
        switch tab {
        case .clipboard:
            if let item = history.list().first(where: { $0.id == selected }) ?? history.list().first { copy(item) }
        case .timer: startOrPause()
        case .shelf, .notes: break
        }
    }

    func handleKey(_ press: KeyPress) -> Bool {
        switch press.key {
        case .upArrow, .downArrow:
            guard tab == .clipboard else { return false }
            let list = history.list()
            guard !list.isEmpty else { return true }
            let index = list.firstIndex { $0.id == selected } ?? -1
            let next = min(max(index + (press.key == .downArrow ? 1 : -1), 0), list.count - 1)
            withAnimation(Theme.snappy) { selected = list[next].id }
            return true
        case .tab:
            let all = tabs.isEmpty ? Tab.allCases : tabs
            let index = all.firstIndex(of: tab) ?? 0
            withAnimation(Theme.snappy) { tab = all[(index + 1) % all.count] }
            return true
        default:
            if press.characters == " ", tab == .timer {
                startOrPause()
                return true
            }
            return false
        }
    }

    func setExpanded(_ expanded: Bool) {
        if !expanded { selected = nil }
        if !expanded {
            notes?.settle()
            notes?.editing = false
        }
    }

    /// Typing a note: the panel stays when the pointer leaves.
    var holdsOpen: Bool { tab == .notes && notes?.editing == true }
}

// MARK: Images

enum ImageFormat: String, CaseIterable {
    case png = "PNG", jpeg = "JPEG", heic = "HEIC", tiff = "TIFF"

    var type: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        case .tiff: .tiff
        }
    }
}

enum ImageConverter {
    enum Failure: Error { case unreadable, unwritable }

    static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    /// Writes `name.ext` next to the original (`name 2.ext` if that exists).
    static func convert(_ url: URL, to format: ImageFormat) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure.unreadable }
        let ext = format.type.preferredFilenameExtension ?? format.rawValue.lowercased()
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        var output = folder.appending(path: "\(base).\(ext)")
        var number = 2
        while FileManager.default.fileExists(atPath: output.path) {
            output = folder.appending(path: "\(base) \(number).\(ext)")
            number += 1
        }
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, format.type.identifier as CFString, 1, nil) else {
            throw Failure.unwritable
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        CGImageDestinationAddImage(destination, image, properties)
        CGImageDestinationSetProperties(destination, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.unwritable }
        return output
    }
}

// MARK: Views

private struct ToolsBody: View {
    @Bindable var module: ToolsModule

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(module.tabs, id: \.self) { tab in
                    let selected = module.tab == tab
                    Button {
                        Haptics.tick()
                        withAnimation(Theme.snappy) { module.tab = tab }
                    } label: {
                        Label(LocalizedStringKey(tab.rawValue), systemImage: tab.symbol)
                            .font(Theme.font(12, .semibold))
                            .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .background(Color.white.opacity(selected ? 0.12 : 0), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PressScale())
                }
                Spacer(minLength: 6)
                if let note = module.note {
                    Text(note).font(Theme.font(11.5)).foregroundStyle(Theme.ok).lineLimit(1)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 4)

            switch module.tab {
            case .clipboard: ClipboardList(module: module)
            case .timer: TimerCard(module: module)
            case .shelf: ShelfCard(module: module)
            case .notes: if let notes = module.notes { NotesCard(store: notes) }
            }
        }
    }
}

private struct ClipboardList: View {
    let module: ToolsModule

    var body: some View {
        NotchCard(padding: 6) {
            let items = module.history.list()
            if items.isEmpty {
                // Centred like the empty shelf, so the panel doesn't read as half built.
                VStack(spacing: 8) {
                    Image(systemName: "doc.on.clipboard").font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    Text("Nothing copied yet").font(Theme.font(13, .semibold)).foregroundStyle(Theme.textPrimary)
                    Text("Copied text shows up here. Click an entry to copy it again. Copies from password apps are never kept, and the list lives in memory only.")
                        .font(Theme.font(12)).foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 400)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 1) {
                            ForEach(items) { item in
                                ClipRow(module: module, item: item, selected: module.selected == item.id).id(item.id)
                            }
                        }
                    }
                    .onChange(of: module.selected) { _, id in
                        if let id { withAnimation(Theme.snappy) { proxy.scrollTo(id) } }
                    }
                }
                HStack {
                    Text(items.count == 1 ? "1 entry" : "\(items.count) entries")
                    Spacer()
                    Button("Clear") { module.clearHistory() }.buttonStyle(PressScale())
                        .help("Removes everything but the pinned entries")
                }
                .font(Theme.font(11)).foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 8)
            }
        }
    }
}

private struct ClipRow: View {
    let module: ToolsModule
    let item: ClipItem
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            HoverRow(cornerRadius: 8, restOpacity: selected ? 0.09 : 0, help: item.text.count > 300 ? String(item.text.prefix(300)) + "…" : item.text) {
                module.copy(item)
            } label: {
                HStack(spacing: 8) {
                    Text(item.line())
                        .font(Theme.font(12.5)).foregroundStyle(Theme.textBody)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(item.copied.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))
                        .font(Theme.font(10.5)).foregroundStyle(Theme.textTertiary)
                        .fixedSize()
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
            }
            if hovering || item.pinned {
                Button { module.togglePin(item) } label: {
                    Image(systemName: item.pinned ? "pin.fill" : "pin")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(item.pinned ? Theme.accent : Theme.textSecondary)
                        .frame(width: 18, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressScale())
                .help(item.pinned ? "Unpin" : "Pin: stays on top and survives Clear")
            }
            if hovering {
                Button { module.remove(item) } label: {
                    Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 16, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressScale())
                .help("Remove")
            }
        }
        .onHover { hovering = $0 }
    }
}

private struct TimerCard: View {
    let module: ToolsModule

    var body: some View {
        // Compact panel: the ring, the kind and its settings beside it, the buttons on the right.
        NotchCard(padding: 12) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let now = context.date
                HStack(spacing: 18) {
                    ring(now: now).frame(width: 90, height: 90)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 4) {
                            ForEach(ToolsModule.TimerKind.allCases, id: \.self) { kind in
                                let selected = module.timerKind == kind
                                Button {
                                    Haptics.tick()
                                    withAnimation(Theme.snappy) { module.timerKind = kind }
                                } label: {
                                    Text(LocalizedStringKey(kind.rawValue))
                                        .font(Theme.font(11.5, .semibold))
                                        .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                                        .padding(.horizontal, 9)
                                        .frame(height: 22)
                                        .background(Color.white.opacity(selected ? 0.12 : 0), in: Capsule())
                                        .contentShape(Capsule())
                                }
                                .buttonStyle(PressScale())
                            }
                        }
                        switch module.timerKind {
                        case .pomodoro: pomodoroControls
                        case .countdown: countdownControls
                        case .stopwatch: EmptyView()
                        }
                    }
                    Spacer(minLength: 0)
                    buttons
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    /// The ring and the time for the kind on show.
    @ViewBuilder private func ring(now: Date) -> some View {
        let pomodoro = module.timerKind == .pomodoro
        let timer = module.timer, simple = module.simple
        let tint = pomodoro ? (timer.phase == .focus || timer.phase == .idle ? Theme.accent : Theme.ok) : Theme.waiting
        let progress = pomodoro ? (timer.phase == .idle ? 0 : timer.progress(at: now))
            : (simple.isActive || module.timerKind == .stopwatch ? simple.progress(at: now) : 0)
        let time = pomodoro ? timer.remaining(at: now)
            : module.timerKind == .stopwatch ? (simple.mode == .stopwatch ? simple.elapsed(at: now) : 0)
            : (simple.mode == .countdown ? simple.remaining(at: now) : simple.duration)
        let label = pomodoro ? timer.phase.title : module.timerKind == .stopwatch ? "Stopwatch" : "Timer"
        ZStack {
            Circle().stroke(Color.white.opacity(0.08), lineWidth: 6)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: tint.opacity(0.6), radius: 4)
            VStack(spacing: 2) {
                Text(Countdown.text(time))
                    .font(Theme.font(19, .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                    .contentTransition(.numericText())
                Text(LocalizedStringKey(label)).font(Theme.font(10.5, .medium)).foregroundStyle(tint)
                if pomodoro {
                    // Today's focus rounds, small under the label.
                    HStack(spacing: 3) {
                        ForEach(0..<max(4, timer.doneToday), id: \.self) { index in
                            Circle().fill(index < timer.doneToday ? Theme.accent : Color.white.opacity(0.14)).frame(width: 4, height: 4)
                        }
                    }
                    .padding(.top, 2)
                    .help("\(timer.doneToday) focus rounds today")
                }
            }
        }
    }

    /// Focus and break lengths (while no round runs), and today's rounds.
    @ViewBuilder private var pomodoroControls: some View {
        let timer = module.timer
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("Focus").font(Theme.font(11)).foregroundStyle(Theme.textTertiary).frame(width: 40, alignment: .leading)
                ForEach([15.0, 25, 45, 60], id: \.self) { minutes in
                    chip("\(Int(minutes))", selected: timer.focusMinutes == minutes, enabled: timer.phase == .idle) {
                        module.setPomodoro(focus: minutes)
                    }
                }
            }
            HStack(spacing: 4) {
                Text("Break").font(Theme.font(11)).foregroundStyle(Theme.textTertiary).frame(width: 40, alignment: .leading)
                ForEach([5.0, 10, 15], id: \.self) { minutes in
                    chip("\(Int(minutes))", selected: timer.breakMinutes == minutes, enabled: timer.phase == .idle) {
                        module.setPomodoro(pause: minutes)
                    }
                }
            }
        }
    }

    /// Presets and ± a minute, while the countdown isn't running.
    @ViewBuilder private var countdownControls: some View {
        let simple = module.simple
        let minutes = simple.duration / 60
        let idle = !simple.isActive
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach([1.0, 5, 10, 15, 30, 60], id: \.self) { value in
                    chip("\(Int(value))", selected: minutes == value, enabled: idle) { module.setCountdown(minutes: value) }
                }
            }
            HStack(spacing: 6) {
                chip("−1", selected: false, enabled: idle && minutes > 1) { module.setCountdown(minutes: minutes - 1) }
                Text("\(Int(minutes)) min").font(Theme.font(11.5).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                chip("+1", selected: false, enabled: idle) { module.setCountdown(minutes: minutes + 1) }
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        let timer = module.timer, simple = module.simple
        VStack(alignment: .trailing, spacing: 6) {
            if module.timerKind == .pomodoro {
                pill(timer.isRunning ? "Pause" : timer.isPaused ? "Resume" : "Start", symbol: timer.isRunning ? "pause.fill" : "play.fill", primary: true) {
                    module.startOrPause()
                }
                if timer.phase != .idle {
                    pill("Skip", symbol: "forward.end.fill") { module.skipPhase() }
                    pill("Stop", symbol: "stop.fill") { module.stopTimer() }
                }
            } else {
                let mine = simple.mode == (module.timerKind == .stopwatch ? .stopwatch : .countdown)
                let running = mine && simple.isRunning
                pill(running ? "Pause" : mine && simple.isActive ? "Resume" : "Start", symbol: running ? "pause.fill" : "play.fill", primary: true) {
                    if simple.isActive && !mine { module.resetSimple() }
                    module.startOrPause()
                }
                if mine && simple.isActive {
                    pill("Reset", symbol: "arrow.counterclockwise") { module.resetSimple() }
                }
            }
        }
    }

    private func chip(_ title: String, selected: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.font(11.5, .semibold).monospacedDigit())
                .foregroundStyle(selected ? Color.white : Theme.textBody)
                .padding(.horizontal, 8)
                .frame(minWidth: 28)
                .frame(height: 22)
                .background(selected ? Theme.accent : Color.white.opacity(0.08), in: Capsule())
        }
        .buttonStyle(PressScale())
        .disabled(!enabled)
        .opacity(enabled || selected ? 1 : 0.45)
    }

    private func pill(_ title: String, symbol: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(LocalizedStringKey(title), systemImage: symbol)
                .font(Theme.font(12, .semibold))
                .foregroundStyle(primary ? Color.white : Theme.textBody)
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(primary ? Theme.accent : Color.white.opacity(0.08), in: Capsule())
        }
        .buttonStyle(PressScale())
    }
}

private struct ShelfCard: View {
    let module: ToolsModule
    @State private var targeted = false

    var body: some View {
        NotchCard(padding: 8) {
            VStack(alignment: .leading, spacing: 6) {
                if module.shelf.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "tray.and.arrow.down").font(.system(size: 22, weight: .semibold))
                        Text(module.converts ? "Drop files here. Drag them out again, AirDrop them, or convert images."
                                             : "Drop files here. Drag them out again or AirDrop them.")
                            .font(Theme.font(12)).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(targeted ? Theme.accent : Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 1) {
                            ForEach(module.shelf, id: \.self) { url in ShelfRow(module: module, url: url) }
                        }
                    }
                    HStack(spacing: 10) {
                        Text(module.shelf.count == 1 ? "1 file" : "\(module.shelf.count) files")
                        Spacer()
                        Button("AirDrop all") { module.airDrop(module.shelf) }.buttonStyle(PressScale())
                        Button("Clear") { module.clearShelf() }.buttonStyle(PressScale())
                    }
                    .font(Theme.font(11)).foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 6)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(targeted ? 0.8 : 0), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        Task { @MainActor in module.add([url]) }
                    }
                }
                return true
            }
        }
    }
}

private struct ShelfRow: View {
    let module: ToolsModule
    let url: URL
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().frame(width: 22, height: 22)
            Text(url.lastPathComponent)
                .font(Theme.font(12.5)).foregroundStyle(Theme.textBody)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if hovering {
                if module.converts, ImageConverter.isImage(url) {
                    Menu {
                        ForEach(ImageFormat.allCases, id: \.self) { format in
                            Button(format.rawValue) { module.convert(url, to: format) }
                        }
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 11, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Convert to …")
                }
                icon("airplayaudio", help: "AirDrop") { module.airDrop([url]) }
                icon("magnifyingglass", help: "Show in Finder") { module.reveal(url) }
                icon("xmark", help: "Remove from the shelf") { module.removeFromShelf(url) }
            }
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 6)
        .frame(height: 30)
        .background(Color.white.opacity(hovering ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onDrag { NSItemProvider(object: url as NSURL) }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
    }

    private func icon(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold))
                .frame(width: 18, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .help(help)
    }
}
