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
        case notes = "Notepad", files = "Files"

        var symbol: String {
            switch self {
            case .clipboard: "doc.on.clipboard"
            case .timer: "timer"
            case .shelf: "tray.and.arrow.down"
            case .notes: "note.text"
            case .files: "folder"
            }
        }
    }

    /// The timer card's three kinds.
    enum TimerKind: String, CaseIterable { case pomodoro = "Pomodoro", countdown = "Timer", stopwatch = "Stopwatch" }

    let kind = ModuleKind.tools
    let symbol = ModuleSymbols.symbol(.tools)

    var tab = Tab.clipboard
    /// The clipboard and the notepad open the large panel, the same size whether the clipboard
    /// has entries or not, so switching between them doesn't resize the island; the timer and the
    /// shelf stay compact.
    var panelSize: PanelSize { tab == .clipboard || tab == .notes || tab == .files ? .large : .compact }
    /// The tabs switched on in Settings › Tools, in the order they were dragged to.
    var tabs = Tab.allCases {
        didSet { if !tabs.contains(tab), let first = tabs.first { tab = first } }
    }
    /// A tab was dragged to a new place: the tabs shown, in their new order, to save.
    @ObservationIgnored var onReorder: (([Tab]) -> Void)?
    /// The image converter is switched on (it works on the shelf's files).
    var converts = true
    /// Quick notes (the daily tools' store), set by the app.
    var notes: NotesStore?
    /// Tara beside the shelf, while Ask Tara is on (set by the app): a file dropped on her opens
    /// her bubble with it (`askAboutFile`) or goes into what she searches (`rememberFile`, true
    /// when it worked). The file is only read, never moved.
    var askAboutFile: ((URL) -> Void)?
    var rememberFile: ((URL) async -> Bool)?
    var cast: AvatarCast?
    /// The file dropped on Tara, waiting for Remember or Ask, and how remembering went.
    enum TaraFile: Equatable { case waiting(URL), remembering(URL), remembered(URL), failed(URL) }
    var taraFile: TaraFile?
    /// The small Finder.
    let files = FilesBrowser()
    private(set) var history = ClipboardHistory()
    private(set) var timer = FocusTimer()
    /// Countdown and stopwatch.
    private(set) var simple = SimpleTimer()
    var timerKind = TimerKind.pomodoro
    private(set) var shelf: [URL] = []
    /// The row under the keyboard in the clipboard list.
    var selected: UUID?
    /// The clipboard's search, shown once the list is long (`ClipboardList.searchFrom`).
    var clipQuery = ""
    /// The search field has the keyboard: the panel stays when the pointer leaves.
    var searchingClips = false
    /// The clipboard as listed: pinned first, then newest, filtered by the search.
    var clips: [ClipItem] { history.list(matching: clipQuery) }
    /// One line after an action ("Copied", "Converted to PNG").
    private(set) var note: String?

    /// A focus or break ended: the app shows a sneak.
    @ObservationIgnored var onPhaseEnd: ((FocusTimer.Phase, FocusTimer.Phase) -> Void)?
    /// A countdown reached zero.
    @ObservationIgnored var onCountdownDone: ((TimeInterval) -> Void)?
    /// Watch the clipboard only while the module is switched on.
    @ObservationIgnored var isEnabled: () -> Bool = { true }
    /// Tara's privacy switches: nothing is kept while paused, with the clipboard off, or from an ignored app.
    @ObservationIgnored var privacy: () -> MemoryPrivacy = { MemoryPrivacy() }
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var lastChange = NSPasteboard.general.changeCount
    /// Counts clipboard changes and clears: an image decoded off the main thread is kept only
    /// while nothing came after it.
    @ObservationIgnored private var clipGeneration = 0
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
        clipGeneration += 1
        guard isEnabled() else { return }
        let types = board.types?.map(\.rawValue) ?? []
        let front = NSWorkspace.shared.frontmostApplication
        let privacy = privacy()
        guard privacy.records(.clipboard, at: Date(), app: front?.bundleIdentifier),
              !ClipboardHistory.shouldSkip(types: types, app: front?.bundleIdentifier, ignored: privacy.ignoredBundleIDs) else { return }
        if let text = board.string(forType: .string) {
            withAnimation(Theme.snappy) { _ = history.add(text, source: front?.localizedName, at: Date()) }
            return
        }
        // An image (a screenshot, an image copied in a browser); not a file copied in Finder,
        // whose icon rides along.
        let png = types.contains(NSPasteboard.PasteboardType.png.rawValue)
        guard !types.contains(NSPasteboard.PasteboardType.fileURL.rawValue),
              png || types.contains(NSPasteboard.PasteboardType.tiff.rawValue) else { return }
        // Read and decoded off the main thread (a large TIFF takes a while); kept only if the
        // clipboard hasn't changed, the history wasn't cleared and recording is still allowed.
        let source = front?.localizedName, app = front?.bundleIdentifier
        let change = board.changeCount, generation = clipGeneration, copied = Date()
        Task { [weak self] in
            let image = await Task.detached(priority: .utility) { () -> ClipImage.Made? in
                let board = NSPasteboard.general
                guard let data = board.data(forType: png ? .png : .tiff), board.changeCount == change else { return nil }
                return ClipImage.make(from: data)
            }.value
            guard let image, let self, self.clipGeneration == generation, self.isEnabled(),
                  self.privacy().records(.clipboard, at: Date(), app: app) else { return }
            withAnimation(Theme.snappy) {
                _ = self.history.addImage(image.png, thumbnail: image.thumbnail, width: image.width, height: image.height,
                                          source: source, at: copied)
            }
        }
    }

    /// Puts an item back on the clipboard (it moves to the top), ready to paste.
    func copy(_ item: ClipItem) {
        let board = NSPasteboard.general
        board.clearContents()
        if let png = item.image {
            // PNG only: apps read it, and a TIFF would be encoded here, on the main thread.
            board.setData(png, forType: .png)
        } else {
            board.setString(item.text, forType: .string)
        }
        lastChange = board.changeCount
        clipGeneration += 1
        Haptics.confirm()
        withAnimation(Theme.snappy) {
            if let png = item.image {
                _ = history.addImage(png, thumbnail: item.thumbnail, width: item.pixelWidth ?? 0, height: item.pixelHeight ?? 0,
                                     source: item.source, at: Date())
            } else {
                _ = history.add(item.text, source: item.source, at: Date())
            }
        }
        show("Copied. Paste with ⌘V")
    }

    func togglePin(_ item: ClipItem) {
        Haptics.tick()
        let changed = withAnimation(Theme.snappy) { history.togglePin(item.id) }
        if !changed { show(Localization.string("No room to pin more images")) }
    }

    func remove(_ item: ClipItem) {
        withAnimation(Theme.snappy) { history.remove(item.id) }
    }

    func clearHistory() {
        clipGeneration += 1
        withAnimation(Theme.snappy) { history.clear() }
    }

    /// Previews: a clipboard with text, links and images (made up, in memory).
    func previewClips() {
        let now = Date()
        func image(_ hue: Double, _ width: Int, _ height: Int) -> (Data, Data?)? {
            let size = NSSize(width: width / 8, height: height / 8)
            let picture = NSImage(size: size, flipped: false) { rect in
                NSGradient(starting: NSColor(hue: hue, saturation: 0.55, brightness: 0.85, alpha: 1),
                           ending: NSColor(hue: hue + 0.1, saturation: 0.6, brightness: 0.45, alpha: 1))?.draw(in: rect, angle: -45)
                return true
            }
            guard let tiff = picture.tiffRepresentation, let made = ClipImage.make(from: tiff) else { return nil }
            return (made.png, made.thumbnail)
        }
        let entries: [(String?, (Data, Data?, Int, Int)?, String, Double)] = [
            ("Ship the clipboard redesign before Friday", nil, "Notes", 40 * 60),
            (nil, image(0.62, 2560, 1600).map { ($0.0, $0.1, 2560, 1600) }, "Screenshot", 32 * 60),
            ("https://developer.apple.com/documentation/eventkit/ekreminder", nil, "Safari", 25 * 60),
            ("swift test --filter ToolsTests", nil, "Terminal", 18 * 60),
            ("Thanks, that works for me. Let's keep Thursday at 10 and move the review to next week.", nil, "Mail", 12 * 60),
            (nil, image(0.08, 1200, 800).map { ($0.0, $0.1, 1200, 800) }, "Preview", 8 * 60),
            ("https://www.example.com/pricing?plan=team", nil, "Chrome", 5 * 60),
            ("Grace Hopper, Compiler Co", nil, "Contacts", 2 * 60),
        ]
        for (text, picture, source, ago) in entries {
            if let text { history.add(text, source: source, at: now.addingTimeInterval(-ago)) }
            if let picture {
                history.addImage(picture.0, thumbnail: picture.1, width: picture.2, height: picture.3, source: source,
                                 at: now.addingTimeInterval(-ago))
            }
        }
        if let pinned = history.list().first(where: { $0.text.hasPrefix("swift test") }) { history.togglePin(pinned.id) }
    }

    /// Previews: the timer card in a state (`stopwatch-paused`, `stopwatch-running`, `timer-paused`, `pomodoro-paused`).
    func previewTimer(_ name: String) {
        let start = Date().addingTimeInterval(-(12 * 60 + 34))
        switch name {
        case "pomodoro-paused":
            timerKind = .pomodoro
            timer.start(at: start)
            timer.pause(at: Date())
        default:
            timerKind = name.hasPrefix("stopwatch") ? .stopwatch : .countdown
            simple.mode = name.hasPrefix("stopwatch") ? .stopwatch : .countdown
            simple.duration = 25 * 60
            simple.start(at: start)
            if name.hasSuffix("paused") { simple.pause(at: Date()) }
        }
        runTicker()
    }

    /// Settings › Tara's memory › Delete: everything, the pinned items too.
    func forgetHistory() {
        clipGeneration += 1
        history = ClipboardHistory()
        selected = nil
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

    // MARK: Tara beside the shelf

    func dropOnTara(_ url: URL) {
        Haptics.confirm()
        withAnimation(Theme.snappy) { taraFile = .waiting(url) }
    }

    func askTara(about url: URL) {
        Haptics.tick()
        taraFile = nil
        askAboutFile?(url)
    }

    func taraRemembers(_ url: URL) {
        guard let rememberFile else { return }
        Haptics.tick()
        withAnimation(Theme.snappy) { taraFile = .remembering(url) }
        Task { [weak self] in
            let done = await rememberFile(url)
            guard let self, self.taraFile == .remembering(url) else { return }
            done ? Haptics.confirm() : Haptics.tick()
            withAnimation(Theme.snappy) { self.taraFile = done ? .remembered(url) : .failed(url) }
            try? await Task.sleep(for: .seconds(done ? 2.4 : 4))
            if self.taraFile == (done ? .remembered(url) : .failed(url)) {
                withAnimation(Theme.snappy) { self.taraFile = nil }
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

    /// One line in the header for a moment ("Moved to Downloads").
    func flash(_ text: String) { show(text) }

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
                // The ear is about 24 pt wide: "12m" fits where "12:35" was cut off; the full
                // time is in the peek line. Paused stays readable, a step dimmer than running.
                Text(Countdown.short(face.time))
                    .font(Theme.font(11, .semibold).monospacedDigit())
                    .foregroundStyle(face.paused ? Theme.textBody : Theme.textPrimary)
                    .lineLimit(1)
                    .fixedSize()
                    .help(Countdown.text(face.time))
            }
        })
    }

    func peekLine() -> AnyView {
        AnyView(TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                if let face = self.face(at: context.date) {
                    // The time first and bright, paused or not; the kind and "Paused" as room allows.
                    let time = Text(Countdown.text(face.time))
                        .font(Theme.font(15, .semibold).monospacedDigit()).foregroundStyle(Theme.textPrimary)
                    let kind = Text(LocalizedStringKey(self.timer.isRunning || self.timer.isPaused ? self.timer.phase.title
                                                       : self.simple.mode == .stopwatch ? "Stopwatch" : "Timer"))
                        .font(Theme.font(12.5, .medium)).foregroundStyle(Theme.textBody)
                    let pause = Image(systemName: "pause.fill").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            time; kind
                            if face.paused { HStack(spacing: 4) { pause; Text("Paused").font(Theme.font(12, .medium)).foregroundStyle(Theme.textSecondary) } }
                        }
                        .fixedSize()
                        HStack(spacing: 8) { if face.paused { pause }; time; kind }.fixedSize()
                        HStack(spacing: 8) { if face.paused { pause }; time }.fixedSize()
                    }
                } else if let last = self.history.list().first {
                    Image(systemName: last.isImage ? "photo" : "doc.on.clipboard").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    Text(verbatim: last.isImage ? last.imageTitle : last.line(60)).font(Theme.font(12.5)).foregroundStyle(Theme.textBody)
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
            if let item = clips.first(where: { $0.id == selected }) ?? clips.first { copy(item) }
        case .timer: startOrPause()
        case .shelf, .notes, .files: break
        }
    }

    func handleKey(_ press: KeyPress) -> Bool {
        switch press.key {
        case .upArrow, .downArrow:
            guard tab == .clipboard else { return false }
            let list = clips
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
        if !expanded {
            selected = nil
            clipQuery = ""
            searchingClips = false
        }
        if !expanded {
            notes?.settle()
            notes?.editing = false
        }
    }

    /// Typing a note: the panel stays when the pointer leaves.
    var holdsOpen: Bool { tab == .notes && notes?.editing == true || tab == .clipboard && searchingClips }
}

// MARK: Images

/// A copied image for the clipboard list: as PNG, a small preview and its size in pixels.
enum ClipImage {
    struct Made: Sendable {
        let png: Data
        let thumbnail: Data?
        let width: Int
        let height: Int
    }

    /// Nil for an image too large to keep: the data's size and the pixel size in its header are
    /// checked before anything is decoded, and a PNG (kept as it is) before it's read at all.
    static func make(from data: Data) -> Made? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              ClipboardHistory.acceptsImage(bytes: data.count, width: width, height: height) else { return nil }
        let isPNG = CGImageSourceGetType(source).map { UTType($0 as String) == .png } == true
        if isPNG, data.count > ClipboardHistory.maxImageBytes { return nil }
        let png = isPNG ? data : CGImageSourceCreateImageAtIndex(source, 0, nil).flatMap(encode)
        guard let png else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 96,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).flatMap(encode)
        return Made(png: png, thumbnail: thumbnail, width: width, height: height)
    }

    private static func encode(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

extension ClipItem {
    /// "Image 2560 × 1600" for the peek line and the command palette, where there is no preview.
    var imageTitle: String {
        guard let width = pixelWidth, let height = pixelHeight, width > 0, height > 0 else { return Localization.string("Image") }
        return Localization.string("Image") + " \(width) × \(height)"
    }
}

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
    /// Press and hold a tab, then drag it sideways: it swaps places as it passes its neighbours,
    /// like the island's own tabs.
    @State private var dragging: ToolsModule.Tab?
    /// Drag distance already spent on swaps; the rest is the tab's offset under the pointer.
    @State private var spent: CGFloat = 0
    @State private var offset: CGFloat = 0
    /// Each tab's width, measured: passing most of a neighbour swaps with it.
    @State private var widths: [ToolsModule.Tab: CGFloat] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: Self.spacing) {
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
                    .offset(x: dragging == tab ? offset : 0)
                    .zIndex(dragging == tab ? 1 : 0)
                    .scaleEffect(dragging == tab && !reduceMotion ? 1.06 : 1)
                    .simultaneousGesture(reorderGesture(tab))
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { widths[tab] = $0 }
                    .help(Text(LocalizedStringKey(tab.rawValue)) + Text(verbatim: " · ") + Text("Hold and drag to move"))
                    .accessibilityHint(Text("Hold and drag to move"))
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
            case .files: FilesCard(module: module)
            }
        }
    }

    private static let spacing: CGFloat = 4

    private func reorderGesture(_ tab: ToolsModule.Tab) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if dragging == nil {
                    dragging = tab
                    spent = 0
                    Haptics.tick()
                }
                guard let drag else { return }
                var rest = drag.translation.width - spent
                let step = rest > 0 ? 1 : -1
                if let index = module.tabs.firstIndex(of: tab), module.tabs.indices.contains(index + step) {
                    let neighbour = (widths[module.tabs[index + step]] ?? 60) + Self.spacing
                    if abs(rest) > neighbour * 0.6 {
                        withAnimation(reduceMotion ? nil : Theme.snappy) { module.tabs.swapAt(index, index + step) }
                        Haptics.tick()
                        spent += CGFloat(step) * neighbour
                        rest = drag.translation.width - spent
                    }
                }
                offset = rest
            }
            .onEnded { _ in
                guard dragging != nil else { return }
                withAnimation(reduceMotion ? nil : Theme.snappy) {
                    dragging = nil
                    offset = 0
                }
                spent = 0
                module.onReorder?(module.tabs)
            }
    }
}

/// The clipboard, newest first and pinned on top: text, web addresses led by their domain and
/// images as small previews. A click copies an entry again (ready for ⌘V); on hover a row offers
/// pin and remove. A search appears once the list is long. In memory only.
private struct ClipboardList: View {
    @Bindable var module: ToolsModule
    @FocusState private var searchFocused: Bool

    /// From this many entries the search shows.
    static let searchFrom = 6

    var body: some View {
        NotchCard(padding: 6) {
            let all = module.history.list()
            if all.isEmpty {
                // Centred like the empty shelf, so the panel doesn't read as half built.
                VStack(spacing: 8) {
                    Image(systemName: "doc.on.clipboard").font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    Text("Nothing copied yet").font(Theme.font(13, .semibold)).foregroundStyle(Theme.textPrimary)
                    Text("Copied text, links and images show up here. Click an entry to copy it again. Copies from password apps are never kept, and the list lives in memory only.")
                        .font(Theme.font(12)).foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 400)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 4) {
                    header(count: all.count)
                    let items = module.clips
                    if items.isEmpty {
                        Text(String(format: Localization.string("Nothing matches “%@”"), module.clipQuery))
                            .font(Theme.font(12)).foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView(.vertical, showsIndicators: false) {
                                LazyVStack(spacing: 1) {
                                    ForEach(items) { item in
                                        ClipRow(module: module, item: item, selected: module.selected == item.id).id(item.id)
                                    }
                                }
                            }
                            .scrollEdgeFade(bottom: 10)
                            .onChange(of: module.selected) { _, id in
                                if let id { withAnimation(Theme.snappy) { proxy.scrollTo(id) } }
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: searchFocused) { _, focus in module.searchingClips = focus }
        .onDisappear { module.searchingClips = false }
    }

    /// The search (when the list is long), the count and Clear.
    private func header(count: Int) -> some View {
        HStack(spacing: 8) {
            if count >= Self.searchFrom {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                    TextField("Search the clipboard", text: $module.clipQuery)
                        .textFieldStyle(.plain)
                        .font(Theme.font(12))
                        .foregroundStyle(Theme.textBody)
                        .focused($searchFocused)
                        .simultaneousGesture(TapGesture().onEnded { NotchPanel.takeKeyboard() })
                        .onSubmit { module.primaryAction() }
                    if !module.clipQuery.isEmpty {
                        Button { module.clipQuery = "" } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                                .foregroundStyle(Theme.textTertiary)
                                .frame(width: 20, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PressScale())
                        .help("Clear the search")
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .frame(maxWidth: 260)
            }
            Spacer(minLength: 4)
            Text(count == 1 ? "1 entry" : "\(count) entries")
            Button("Clear") { module.clearHistory() }.buttonStyle(PressScale())
                .help("Removes everything but the pinned entries")
        }
        .font(Theme.font(11)).foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }
}

private struct ClipRow: View {
    let module: ToolsModule
    let item: ClipItem
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            HoverRow(cornerRadius: 9, restOpacity: selected ? 0.09 : 0, help: help) {
                module.copy(item)
            } label: {
                HStack(spacing: 10) {
                    leading
                    VStack(alignment: .leading, spacing: 1) {
                        title.lineLimit(1).truncationMode(.tail)
                        detail.font(Theme.font(10.5)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
                .padding(.horizontal, 6)
                .frame(height: 38)
            }
            // Pin and remove on hover; a pinned entry keeps its pin.
            Button { module.togglePin(item) } label: {
                Image(systemName: item.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(item.pinned ? Theme.accent : Theme.textSecondary)
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressScale())
            .help(item.pinned ? "Unpin" : "Pin: stays on top and survives Clear")
            .opacity(hovering || item.pinned ? 1 : 0)
            .allowsHitTesting(hovering || item.pinned)
            Button { module.remove(item) } label: {
                Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressScale())
            .help("Remove")
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
        }
        .onHover { hovering = $0 }
    }

    /// The image's preview, or what kind of copy it is.
    @ViewBuilder private var leading: some View {
        if let data = item.thumbnail ?? item.image, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
        } else {
            Image(systemName: item.isImage ? "photo" : item.link != nil ? "link" : "text.alignleft")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 28, height: 28)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    @ViewBuilder private var title: some View {
        if item.isImage {
            (Text("Image") + Text(verbatim: size.map { "  \($0)" } ?? "").foregroundColor(Theme.textSecondary))
                .font(Theme.font(12.5, .medium)).foregroundStyle(Theme.textBody)
        } else if let link = item.link {
            (Text(verbatim: link.domain).foregroundColor(Theme.textPrimary) + Text(verbatim: link.rest).foregroundColor(Theme.textSecondary))
                .font(Theme.font(12.5, .medium))
        } else {
            Text(verbatim: item.line()).font(Theme.font(12.5)).foregroundStyle(Theme.textBody)
        }
    }

    /// The app it came from and when: "Safari · 5 min ago".
    private var detail: Text {
        let when = item.copied.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
        return Text(verbatim: [item.source, when].compactMap { $0 }.joined(separator: " · "))
    }

    private var size: String? {
        guard let width = item.pixelWidth, let height = item.pixelHeight, width > 0 else { return nil }
        return "\(width) × \(height)"
    }

    private var help: String {
        if item.isImage { return Localization.string("Click to copy the image again") }
        return item.text.count > 300 ? String(item.text.prefix(300)) + "…" : item.text
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
                    // The kinds and the presets take their width first; they were cut to "…" in
                    // the compact panel.
                    .layoutPriority(1)
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
        HStack(spacing: 8) {
            shelf
            // Beside the shelf, while Ask Tara is on: Tara takes a file to remember or ask about.
            if module.askAboutFile != nil { TaraDropCard(module: module) }
        }
    }

    private var shelf: some View {
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

/// Tara beside the shelf: drop a file on her, then Remember (its text goes where she searches)
/// or Ask (her bubble opens with it). Dropping here never copies or moves the file.
private struct TaraDropCard: View {
    let module: ToolsModule
    @State private var targeted = false
    @State private var received = 0

    var body: some View {
        NotchCard(padding: 8) {
            VStack(spacing: 6) {
                if let cast = module.cast {
                    AvatarView(character: cast.main, mood: mood, height: 34, colorway: cast.colorway, emergeOnAppear: false)
                        .frame(height: 36)
                        .scaleEffect(targeted ? 1.15 : 1)
                        // She hops when she takes a file, and again when she has remembered it.
                        .modifier(LandingBounce(trigger: received))
                }
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(targeted ? 0.8 : 0), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
            .onDrop(of: FileDrop.types, isTargeted: $targeted) { providers in
                FileDrop.load(providers) { module.dropOnTara($0) }
            }
        }
        .frame(width: 184)
        .animation(Theme.snappy, value: targeted)
        .animation(Theme.snappy, value: module.taraFile)
        .onChange(of: module.taraFile) { _, file in
            switch file {
            case .waiting, .remembered: received += 1
            default: break
            }
        }
    }

    private var mood: AvatarMood {
        if targeted { return .listening }
        switch module.taraFile {
        case .remembering: return .thinking
        case .remembered: return .finished
        case .failed: return .failed
        case .waiting, nil: return .idle
        }
    }

    @ViewBuilder private var content: some View {
        switch module.taraFile {
        case nil:
            Text(targeted ? "Let go on Tara" : "Drop a file on Tara to remember it or ask about it")
                .font(Theme.font(11.5))
                .foregroundStyle(targeted ? Theme.accent : Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        case .waiting(let url):
            name(url)
            HStack(spacing: 4) {
                action("Remember", symbol: "brain") { module.taraRemembers(url) }
                action("Ask", symbol: "bubble.left", primary: true) { module.askTara(about: url) }
            }
            Button { withAnimation(Theme.snappy) { module.taraFile = nil } } label: {
                Text("Cancel").font(Theme.font(11)).foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(PressScale())
        case .remembering(let url):
            name(url)
            ProgressView().controlSize(.small)
        case .remembered:
            Label("Tara keeps it", systemImage: "checkmark.circle.fill")
                .font(Theme.font(12, .medium))
                .foregroundStyle(Theme.ok)
            Text("Documents › Starnotch › Documents").font(Theme.font(10.5)).foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
        case .failed:
            Text("Tara can read PDFs, Word and text files; this one has no text she can read")
                .font(Theme.font(11.5))
                .foregroundStyle(Theme.waiting)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func name(_ url: URL) -> some View {
        Text(url.lastPathComponent)
            .font(Theme.font(12, .medium))
            .foregroundStyle(Theme.textBody)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private func action(_ title: LocalizedStringKey, symbol: String, primary: Bool = false, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title, systemImage: symbol)
                .labelStyle(.titleAndIcon)
                .font(Theme.font(11.5, .semibold))
                .fixedSize()
                .foregroundStyle(primary ? Color.white : Theme.textBody)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(primary ? Theme.accent : Color.white.opacity(0.08), in: Capsule())
        }
        .buttonStyle(PressScale())
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
