import AppKit
import NotchCore
import Observation
import SwiftUI

/// Now Playing in three stages: ears (cover, equalizer, no text), hover (cover, title, one play
/// button, hairline progress), panel (cover with source badge and glow, scrubber, controls).
/// The cover's dominant color is the only extra color. Live data comes from any app through
/// MediaRemote (`MediaRemoteBridge`: Spotify, Music, Podcasts, VLC, IINA, YouTube or SoundCloud in
/// a browser), with AppleScript for Spotify and Music as the fallback (`PlayerBridge`).
/// Two tools sit inside: synced lyrics (one line in the panel, optionally on hover) and a mixer
/// with each app's volume, in a popover.
@MainActor
@Observable
final class NowPlayingModule: NotchModule {
    struct Track: Equatable, Identifiable {
        var id: String
        var title: String
        var artist: String
        var duration: TimeInterval
        var color: Color
        var cover: NSImage
        var source: PlayerStatus.Source?
        var album = ""
        /// The app that plays (its icon is the cover's badge).
        var appID: String?
        /// From MediaRemote: controls go there instead of AppleScript.
        var remote = false
    }

    let kind = ModuleKind.nowPlaying
    let symbol = ModuleSymbols.symbol(.nowPlaying)

    private(set) var track: Track?
    private(set) var isPlaying = false
    private(set) var position: TimeInterval = 0
    /// When `position` was true; with `isPlaying`, the position at any moment (lyrics).
    @ObservationIgnored private var positionDate = Date()
    /// +1 next, -1 previous: content slides that way.
    private(set) var direction: CGFloat = 1
    let cast: AvatarCast
    /// Output device and volume (CoreAudio).
    let output = AudioOutput()
    /// Volume per app (the App volume tool).
    let mixer = AppVolumeMixer()
    /// The output list, floating over the card. While it shows, the island holds its lock so
    /// it doesn't collapse when the pointer wanders; a click outside closes the list.
    var showsOutputs = false {
        didSet {
            guard showsOutputs != oldValue else { return }
            if showsOutputs { showsMixer = false }
            lock(showsOutputs, "output list", token: &outputLock) { [weak self] in self?.showsOutputs = false }
        }
    }
    /// The mixer, floating over the card like the output list.
    var showsMixer = false {
        didSet {
            guard showsMixer != oldValue else { return }
            if showsMixer { showsOutputs = false; mixer.reload() }
            lock(showsMixer, "mixer", token: &mixerLock) { [weak self] in self?.showsMixer = false }
        }
    }
    @ObservationIgnored private var outputLock: Int?
    @ObservationIgnored private var mixerLock: Int?
    @ObservationIgnored var onTrackChange: ((Track) -> Void)?
    /// Tara pulled down out of the ear: she leaves the notch and follows the pointer.
    @ObservationIgnored var onFigurePull: (() -> Void)?

    /// Tools, set from the Tools gallery.
    var lyricsOn = false {
        didSet { if lyricsOn != oldValue { loadLyrics() } }
    }
    var lyricsOnHover = false
    var mixerOn = false {
        didSet {
            guard mixerOn != oldValue else { return }
            if mixerOn { if !mock { mixer.start() } } else { showsMixer = false; mixer.stop() }
        }
    }
    /// The current track's synced lyrics, when the tool is on and LRCLIB has them.
    private(set) var lyrics: SyncedLyrics?
    @ObservationIgnored private let lyricsStore = LyricsStore()
    @ObservationIgnored private var lyricsTask: Task<Void, Never>?

    @ObservationIgnored private var mockTracks: [Track] = []
    @ObservationIgnored private var mockIndex = 0
    @ObservationIgnored private var mock = false
    @ObservationIgnored private var clock: Task<Void, Never>?
    @ObservationIgnored private var live = false
    @ObservationIgnored private var lastStatus: PlayerStatus?
    @ObservationIgnored private let remote = MediaRemoteBridge()
    @ObservationIgnored private var remoteCover: String?
    /// After a click, the player's old state still comes in for a moment: it doesn't undo the click.
    @ObservationIgnored private var holdPlayUntil = Date.distantPast
    @ObservationIgnored private var pendingSeek: (target: TimeInterval, at: Date)?
    @ObservationIgnored private var ticks = 0

    init(cast: AvatarCast) {
        self.cast = cast
    }

    private func lock(_ on: Bool, _ reason: String, token: inout Int?, dismiss: @escaping () -> Void) {
        if on {
            token = IslandLock.shared.acquire(reason) { withAnimation(Theme.snappy) { dismiss() } }
        } else if let held = token {
            token = nil
            IslandLock.shared.release(held)
        }
    }

    // MARK: Sources

    /// Recordings: two invented tracks with covers drawn in code, invented lyrics, sample apps.
    func start() {
        mock = true
        mockTracks = MockCovers.tracks()
        track = mockTracks[0]
        isPlaying = true
        setPosition(47)
        lyrics = MockCovers.lyrics(for: mockTracks[0].id)
        mixer.stop()
        mixer.usePreview()
        clock?.cancel()
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.isPlaying, let track = self.track else { continue }
                self.setPosition(self.position + 0.5)
                if self.position >= track.duration { self.next() }
            }
        }
    }

    /// Music's switch in the Tools gallery: off, the helper and the clock stop and no track
    /// reaches the notch.
    var musicOn = true {
        didSet {
            guard live, musicOn != oldValue else { return }
            if musicOn { resumeLive() } else { pauseLive() }
        }
    }

    /// Any app through MediaRemote, updated as it changes. Only when the system-wide source isn't
    /// there (or gave up), Spotify and Music through AppleScript, polled every 1.5 s while one of
    /// them runs; nothing is sent to an app that isn't running.
    func startLive() {
        live = true
        remote.onUpdate = { [weak self] in self?.refresh(fromRemote: true) }
        if musicOn { resumeLive() }
    }

    private func resumeLive() {
        remote.start()
        clock?.cancel()
        clock = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.ticks += 1
                if self.remoteSnapshot != nil {
                    self.refresh(fromRemote: false)
                } else if !self.remote.isAvailable, self.ticks % 3 == 0 || self.track?.remote == true {
                    await self.poll()
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func pauseLive() {
        clock?.cancel()
        clock = nil
        remote.stop()
        lastStatus = nil
        remoteCover = nil
        track = nil
        isPlaying = false
        loadLyrics()
    }

    private var remoteSnapshot: MediaSnapshot? {
        if case .playing(let snapshot)? = remote.current { return snapshot }
        return nil
    }

    /// MediaRemote's view: a new line (`fromRemote`) or the clock moving the position on.
    private func refresh(fromRemote: Bool) {
        guard let snapshot = remoteSnapshot else {
            // Nothing plays (or the helper ended); without the helper, the AppleScript poll decides.
            if fromRemote, track?.remote == true { withAnimation(Theme.close) { track = nil; isPlaying = false } }
            return
        }
        let now = Date()
        if let seek = pendingSeek, now.timeIntervalSince(seek.at) < 2, (snapshot.timestamp ?? .distantPast) < seek.at {
            setPosition(seek.target + (isPlaying ? now.timeIntervalSince(seek.at) : 0), at: now)
        } else {
            pendingSeek = nil
            setPosition(snapshot.position(at: now), at: now)
        }
        if now >= holdPlayUntil || fromRemote, isPlaying != snapshot.isPlaying {
            if fromRemote { holdPlayUntil = .distantPast }
            withAnimation(Theme.snappy) { isPlaying = snapshot.isPlaying }
        }
        let key = snapshot.trackKey
        if track?.id == key {
            // The cover often comes a moment after the title.
            if remoteCover != key, var current = track, let artwork = remote.artwork(for: snapshot).flatMap(NSImage.init(data:)) {
                remoteCover = key
                current.cover = artwork
                current.color = DominantColor.of(artwork)
                track = current
            }
            return
        }
        let artwork = remote.artwork(for: snapshot).flatMap(NSImage.init(data:))
        remoteCover = artwork == nil ? nil : key
        let cover = artwork ?? MockCovers.placeholder()
        let new = Track(id: key, title: snapshot.title, artist: snapshot.artist, duration: snapshot.duration,
                        color: DominantColor.of(cover), cover: cover, source: PlayerBridge.source(for: snapshot.appID),
                        album: snapshot.album, appID: snapshot.appID.isEmpty ? nil : snapshot.appID, remote: true)
        show(new)
    }

    private func poll() async {
        guard let status = PlayerBridge.status() else {
            if track != nil { withAnimation(Theme.close) { track = nil; isPlaying = false } }
            lastStatus = nil
            return
        }
        let changed = status.trackID != lastStatus?.trackID || track?.remote == true
        lastStatus = status
        setPosition(status.position)
        if isPlaying != status.isPlaying { withAnimation(Theme.snappy) { isPlaying = status.isPlaying } }
        guard changed else { return }
        let cover = await PlayerBridge.artwork(for: status) ?? MockCovers.placeholder()
        // MediaRemote may have come back while the cover loaded.
        guard remoteSnapshot == nil else { return }
        show(Track(id: status.trackID, title: status.title, artist: status.artist, duration: status.duration,
                   color: DominantColor.of(cover), cover: cover, source: status.source, album: status.album,
                   appID: PlayerBridge.bundleIDs[status.source]))
    }

    private func show(_ new: Track) {
        let hadTrack = track != nil
        withAnimation(Theme.open) { track = new }
        loadLyrics()
        if hadTrack { onTrackChange?(new) }
    }

    private func setPosition(_ seconds: TimeInterval, at date: Date = Date()) {
        position = seconds
        positionDate = date
    }

    /// The position right now, between two updates (the lyrics read it several times a second).
    func position(at date: Date) -> TimeInterval {
        guard isPlaying else { return position }
        let moved = position + max(0, date.timeIntervalSince(positionDate))
        return track.map { $0.duration > 0 ? min(moved, $0.duration) : moved } ?? moved
    }

    // MARK: Lyrics

    private func loadLyrics() {
        lyricsTask?.cancel()
        guard lyricsOn, let track else { lyrics = nil; return }
        if mock { lyrics = MockCovers.lyrics(for: track.id); return }
        let query = LRCLIB.Query(title: track.title, artist: track.artist, album: track.album, duration: track.duration)
        lyrics = lyricsStore.cached(query)
        guard lyrics == nil else { return }
        lyricsTask = Task { [weak self] in
            guard let self else { return }
            let found = await self.lyricsStore.lyrics(for: query)
            guard !Task.isCancelled, self.track?.id == track.id else { return }
            withAnimation(Theme.snappy) { self.lyrics = found }
        }
    }

    /// The line sung at `date`, slightly ahead so it reads as it is sung.
    func lyricLine(at date: Date) -> (index: Int, text: String)? {
        guard lyricsOn, let lyrics else { return nil }
        let at = position(at: date) + 0.25
        guard let index = lyrics.index(at: at), let text = lyrics.line(at: at) else { return nil }
        return (index, text)
    }

    // MARK: Controls

    func togglePlay() {
        Haptics.tick()
        if live, let track {
            if track.remote { remote.send(.togglePlayPause) } else if let source = track.source { PlayerBridge.send("playpause", to: source) }
            holdPlayUntil = Date().addingTimeInterval(1.5)
        }
        setPosition(position(at: Date()))
        withAnimation(Theme.snappy) { isPlaying.toggle() }
    }

    func next() { step(1) }
    func previous() { step(-1) }

    /// Jumps within the track (the scrubber); the next update confirms the player's position.
    func seek(to seconds: TimeInterval) {
        guard let track else { return }
        let target = min(max(0, seconds), track.duration)
        if live {
            if track.remote {
                remote.seek(to: target)
                pendingSeek = (target, Date())
            } else if let source = track.source {
                PlayerBridge.send("set player position to \(Int(target.rounded()))", to: source, cached: false)
            }
        }
        setPosition(target)
    }

    private func step(_ delta: Int) {
        Haptics.tick()
        direction = CGFloat(delta)
        if live {
            if track?.remote == true {
                remote.send(delta > 0 ? .next : .previous)
            } else if let source = track?.source {
                PlayerBridge.send(delta > 0 ? "next track" : "previous track", to: source)
            }
            return  // the next update picks up the new track
        }
        guard !mockTracks.isEmpty else { return }
        mockIndex = (mockIndex + delta + mockTracks.count) % mockTracks.count
        withAnimation(Theme.open) {
            track = mockTracks[mockIndex]
            setPosition(0)
            isPlaying = true
        }
        loadLyrics()
        if let track { onTrackChange?(track) }
    }

    // MARK: NotchModule

    /// Beside the notch while music plays; agents at work keep the ears (they show a small
    /// equalizer next to their count instead).
    var ambientPriority: Int { isPlaying && track != nil ? 15 : 0 }

    func setExpanded(_ expanded: Bool) {
        if !expanded {
            showsOutputs = false
            showsMixer = false
        }
    }

    func handleBack() -> Bool {
        guard showsOutputs || showsMixer else { return false }
        withAnimation(Theme.snappy) {
            showsOutputs = false
            showsMixer = false
        }
        return true
    }

    /// Tara listens along with a note beside her; she stays the handle to pull out of the notch.
    func leadingEar(peek: Bool) -> AnyView {
        guard track != nil else { return AnyView(EmptyView()) }
        return AnyView(MusicEarFigure(module: self, peek: peek))
    }

    /// The cover; with room (a roomy peek) the equalizer beside it.
    func trailingEar(peek: Bool) -> AnyView {
        guard let track else { return AnyView(EmptyView()) }
        return AnyView(HStack(spacing: 6) {
            if peek { Equalizer(color: track.color, playing: isPlaying, height: 12) }
            CoverView(track: track, size: peek ? 24 : 20, badge: false)
                .id(track.id)
                .transition(.blurSlide(scale: 0.8))
        })
    }

    /// Hover: title (or, with Lyrics on hover, the line being sung), one play button, hairline
    /// progress. No artist, no other controls.
    func peekLine() -> AnyView {
        AnyView(HStack(alignment: .bottom, spacing: 10) {
            // Tara moves down from the ear into the line, bigger, with her note.
            if track != nil {
                MusicFigure(module: self, height: 34)
                    .frame(width: 38, height: 38, alignment: .bottom)
                    .musicFigureMatched()
            }
            peekText
                .padding(.bottom, 9)
        }
        .frame(maxHeight: .infinity, alignment: .bottom))
    }

    private var peekText: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                if lyricsOnHover, lyrics != nil {
                    LyricLine(module: self, size: 13, weight: .semibold, color: Theme.textPrimary,
                              fallback: track?.title ?? "")
                } else {
                    Text(track?.title ?? "Nothing playing")
                        .font(Theme.font(13, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if track != nil {
                    Button { self.togglePlay() } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.textBody)
                            .frame(width: 26, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScale())
                    .contentTransition(.symbolEffect(.replace))
                }
            }
            if let track {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.12))
                        Capsule().fill(Color.white.opacity(0.7))
                            .frame(width: proxy.size.width * min(1, self.position / max(1, track.duration)))
                    }
                }
                .frame(height: 1.5)
                .animation(.linear(duration: 0.5), value: position)
            }
        }
        .id(track?.id)
        .transition(.blurSlide(x: 14 * direction))
    }

    func body() -> AnyView { AnyView(NowPlayingBody(module: self)) }

    func primaryAction() { togglePlay() }
}

/// Tara in the leading ear while music plays, a note beside her; in the peek she sits in the line.
private struct MusicEarFigure: View {
    let module: NowPlayingModule
    let peek: Bool
    @Environment(\.islandPeek) private var islandPeek

    var body: some View {
        if islandPeek {
            Color.clear
        } else {
            MusicFigure(module: module, height: peek ? 28 : 25, sink: peek ? 0 : 0.25)
                .frame(height: 32, alignment: .bottom)
                .musicFigureMatched()
                .clipped()
        }
    }
}

private extension View {
    /// The same figure in the ear and the peek line: it travels between them.
    func musicFigureMatched() -> some View { modifier(MusicFigureMatch()) }
}

private struct MusicFigureMatch: ViewModifier {
    @Environment(\.notch) private var notch
    func body(content: Content) -> some View { content.notchMatched("music.main", in: notch.namespace) }
}

/// Tara listening along: squashes with the island's press and pulls out of the notch.
private struct MusicFigure: View {
    let module: NowPlayingModule
    let height: CGFloat
    var sink: CGFloat = 0
    @State private var pulling = false

    var body: some View {
        AvatarView(character: module.cast.main, mood: module.isPlaying ? .music : .idle,
                   height: height, colorway: module.cast.colorway, sink: sink, emergeOnAppear: false,
                   musicNote: module.isPlaying)
            .handleSquash()
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .global)
                .onChanged { value in
                    // Pulled down past the notch: she leaves it and follows the pointer.
                    guard !pulling, value.translation.height > 24 else { return }
                    pulling = true
                    module.onFigurePull?()
                }
                .onEnded { _ in pulling = false })
    }
}

/// The line being sung, one line, the next sliding up in its place (fades only with reduce
/// motion). Reads the position several times a second without touching the rest of the card.
struct LyricLine: View {
    let module: NowPlayingModule
    var size: CGFloat = 13
    var weight: Font.Weight = .medium
    var color: Color = Theme.textBody
    /// Shown before the first line and in instrumental gaps; empty shows a quiet note.
    var fallback = ""

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { context in
            let line = module.lyricLine(at: context.date)
            ZStack(alignment: .leading) {
                Group {
                    if let line {
                        Text(line.text).foregroundStyle(color)
                    } else if !fallback.isEmpty {
                        Text(fallback).foregroundStyle(color)
                    } else {
                        Image(systemName: "music.note").foregroundStyle(Theme.textTertiary)
                    }
                }
                .font(Theme.font(size, weight))
                .lineLimit(1)
                .id(line?.index ?? -1)
                .transition(Theme.reduceMotion ? .opacity
                            : .asymmetric(insertion: .offset(y: 8).combined(with: .opacity),
                                          removal: .offset(y: -8).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            .animation(.easeOut(duration: 0.2), value: line?.index ?? -1)
        }
        .accessibilityLabel("Lyrics")
    }
}

private struct NowPlayingBody: View {
    let module: NowPlayingModule

    var body: some View {
        Group {
            if let track = module.track {
                player(track)
            } else {
                idle
            }
        }
        .overlayPreferenceValue(OutputButtonAnchor.self) { anchor in
            GeometryReader { proxy in
                if module.showsOutputs, let anchor {
                    OutputPopover(output: module.output, button: proxy[anchor], in: proxy.size) {
                        withAnimation(Theme.snappy) { module.showsOutputs = false }
                    }
                }
            }
        }
        .overlayPreferenceValue(MixerButtonAnchor.self) { anchor in
            GeometryReader { proxy in
                if module.showsMixer, let anchor {
                    MixerPopover(mixer: module.mixer, button: proxy[anchor], in: proxy.size) {
                        withAnimation(Theme.snappy) { module.showsMixer = false }
                    }
                }
            }
        }
    }

    /// Nothing playing: the same layout with an empty cover; the output and its volume still work.
    private var idle: some View {
        HStack(alignment: .center, spacing: 16) {
            RoundedRectangle(cornerRadius: Self.cover * 0.22, style: .continuous)
                .fill(Theme.cardHover)
                .frame(width: Self.cover, height: Self.cover)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nothing playing").font(Theme.font(15, .semibold)).foregroundStyle(Theme.textPrimary)
                    Text(MediaRemoteBridge.isUsable ? "Play something in any app and it shows up here."
                                                    : "Play something in Spotify or Music and it shows up here.")
                        .font(Theme.font(12)).foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    outputRow
                }
            }
            .frame(maxHeight: Self.cover)
        }
        .padding(.horizontal, Self.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// Volume, then the mixer (with the Volume per app tool) and the output device as symbols; a
    /// click on either opens its list (the device's name is in the list and the help tag).
    private var outputRow: some View {
        HStack(spacing: 8) {
            VolumeSlider(output: module.output, width: 64)
            if module.mixerOn {
                MixerButton(open: Binding(get: { module.showsMixer }, set: { module.showsMixer = $0 }))
            }
            OutputButton(output: module.output, open: Binding(get: { module.showsOutputs },
                                                              set: { module.showsOutputs = $0 }),
                         showsName: false)
        }
    }

    /// The compact panel: the cover on the left; title and artist with the listening character,
    /// the scrubber, then the controls with volume and output on one line.
    private func player(_ track: NowPlayingModule.Track) -> some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(track.color.opacity(0.5))
                    .frame(width: Self.cover, height: Self.cover)
                    .blur(radius: 22)
                CoverView(track: track, size: Self.cover, badge: true)
                    .shadow(color: .black.opacity(0.4), radius: 10, y: 5)
            }
            .id(track.id)
            .transition(.blurSlide(x: 30 * module.direction, scale: 0.92))

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(Theme.font(15, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(track.album.isEmpty ? track.artist : "\(track.artist) · \(track.album)")
                            .font(Theme.font(12))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .lineLimit(1)
                    .id(track.id)
                    .transition(.blurSlide(x: 20 * module.direction))
                    Spacer(minLength: 0)
                    // The main character listens along, a note beside her while it plays.
                    AvatarView(character: module.cast.main, mood: .music, height: 34,
                               colorway: module.cast.colorway, emergeOnAppear: false, musicNote: module.isPlaying)
                        .frame(width: 40, height: 36, alignment: .top)
                }

                // Synced lyrics: the line being sung, between the title and the scrubber.
                if module.lyricsOn, module.lyrics != nil {
                    LyricLine(module: module, size: 12.5, weight: .medium, color: Theme.textBody)
                        .padding(.top, 5)
                        .transition(.opacity)
                }

                Spacer(minLength: 2)

                Scrubber(position: module.position, duration: track.duration) { module.seek(to: $0) }

                HStack(spacing: 4) {
                    control("backward.fill", size: 13, label: "Previous") { module.previous() }
                    control(module.isPlaying ? "pause.fill" : "play.fill", size: 18,
                            label: module.isPlaying ? "Pause" : "Play") { module.togglePlay() }
                        .contentTransition(.symbolEffect(.replace))
                    control("forward.fill", size: 13, label: "Next") { module.next() }
                    Spacer(minLength: 8)
                    outputRow
                }
                .padding(.leading, -7)
            }
            .frame(maxHeight: Self.cover)
        }
        .padding(.horizontal, Self.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .animation(Theme.open, value: track.id)
    }

    /// Sized for the compact panel (150 high): the cover fills it with an even margin.
    static let cover: CGFloat = 118
    static let inset: CGFloat = 16

    private func control(_ symbol: String, size: CGFloat, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(label)
    }
}

/// Thin scrubber: the played part in white, times small and quiet, remaining time negative.
/// A click or drag anywhere along it (the times included, about 30 pt tall) jumps there.
private struct Scrubber: View {
    let position: TimeInterval
    let duration: TimeInterval
    var onSeek: ((TimeInterval) -> Void)?
    /// While dragging: the fraction under the pointer, shown before the player catches up.
    @State private var dragged: Double?

    var body: some View {
        let fraction = dragged ?? (duration > 0 ? min(1, position / duration) : 0)
        let shown = dragged.map { $0 * duration } ?? position
        GeometryReader { proxy in
            VStack(spacing: 0) {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.14))
                    Capsule().fill(Color.white.opacity(0.85)).frame(width: proxy.size.width * fraction)
                }
                .frame(height: 3)
                .scaleEffect(x: 1, y: dragged == nil ? 1 : 1.7)
                .frame(height: 13)
                HStack {
                    Text(Self.time(shown))
                    Spacer()
                    Text("-" + Self.time(max(0, duration - shown)))
                }
                .font(Theme.font(11.5).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard onSeek != nil, duration > 0 else { return }
                    dragged = min(1, max(0, value.location.x / max(1, proxy.size.width)))
                }
                .onEnded { _ in
                    if let dragged { onSeek?(dragged * duration) }
                    dragged = nil
                })
        }
        .frame(height: 29)
        .animation(dragged == nil ? .linear(duration: 0.5) : nil, value: position)
        .animation(Theme.snappy, value: dragged == nil)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Position")
    }

    static func time(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Rounded cover; with `badge`, the source app's icon sits small in the corner.
struct CoverView: View {
    let track: NowPlayingModule.Track
    let size: CGFloat
    var badge = false

    var body: some View {
        Image(nsImage: track.cover)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fill)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if badge, let icon = track.appID.flatMap(PlayerBridge.icon(forApp:)) {
                    // Small at every cover size: a hint of the source, not a second cover.
                    let side = min(28, max(12, size * 0.24))
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: side, height: side)
                        .shadow(color: .black.opacity(0.5), radius: 2)
                        .offset(x: side * 0.25, y: side * 0.25)
                }
            }
    }
}

/// Talks to Spotify and Music through AppleScript, only when the app is running.
@MainActor
enum PlayerBridge {
    static let bundleIDs: [PlayerStatus.Source: String] = [.spotify: "com.spotify.client", .music: "com.apple.Music"]
    static let names: [PlayerStatus.Source: String] = [.spotify: "Spotify", .music: "Music"]
    private static var scripts: [String: NSAppleScript] = [:]

    static func isRunning(_ source: PlayerStatus.Source) -> Bool {
        guard let id = bundleIDs[source] else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
    }

    /// The playing source wins; a paused one shows when nothing plays.
    static func status() -> PlayerStatus? {
        let statuses = [PlayerStatus.Source.spotify, .music].filter(isRunning).compactMap(query)
        return statuses.first(where: \.isPlaying) ?? statuses.first
    }

    private static func query(_ source: PlayerStatus.Source) -> PlayerStatus? {
        let app = names[source]!
        let id = source == .spotify ? "id of t" : "persistent ID of t"
        let artwork = source == .spotify ? "artwork url of t" : "\"\""
        let script = """
        tell application "\(app)"
            if player state is stopped then return "stopped"
            set t to current track
            return (player state as string) & "||" & (name of t) & "||" & (artist of t) & "||" & (duration of t) & "||" & (player position) & "||" & \(artwork) & "||" & \(id) & "||" & (album of t)
        end tell
        """
        guard let reply = run(script) else { return nil }
        return PlayerStatus.parse(reply, source: source)
    }

    /// `cached: false` for a command with a value in it (a seek), so the cache doesn't fill
    /// with one compiled script per second of the track.
    static func send(_ command: String, to source: PlayerStatus.Source, cached: Bool = true) {
        guard isRunning(source), let app = names[source] else { return }
        _ = run("tell application \"\(app)\" to \(command)", cached: cached)
    }

    static func artwork(for status: PlayerStatus) async -> NSImage? {
        if let url = status.artworkURL {
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            return NSImage(data: data)
        }
        guard status.source == .music, isRunning(.music) else { return nil }
        let script = NSAppleScript(source: "tell application \"Music\" to get raw data of artwork 1 of current track")
        var error: NSDictionary?
        guard let descriptor = script?.executeAndReturnError(&error) else { return nil }
        return NSImage(data: descriptor.data)
    }

    static func icon(for source: PlayerStatus.Source) -> NSImage? {
        bundleIDs[source].flatMap(icon(forApp:))
    }

    private static var icons: [String: NSImage] = [:]

    /// Any app's icon by bundle id (the badge for a browser, VLC, Podcasts), remembered.
    static func icon(forApp id: String) -> NSImage? {
        if let icon = icons[id] { return icon }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[id] = icon
        return icon
    }

    /// The AppleScript source behind a MediaRemote app, when there is one.
    static func source(for appID: String) -> PlayerStatus.Source? {
        bundleIDs.first { $0.value == appID }?.key
    }

    /// The app's name as the user knows it.
    static func name(forApp id: String) -> String {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first, let name = app.localizedName { return name }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return id.split(separator: ".").last.map(String.init) ?? id
    }

    private static func run(_ source: String, cached: Bool = true) -> String? {
        let script = scripts[source] ?? NSAppleScript(source: source)
        if cached { scripts[source] = script }
        var error: NSDictionary?
        guard let result = script?.executeAndReturnError(&error), error == nil else { return nil }
        return result.stringValue
    }
}

/// The most vivid color of a cover (saturation × brightness), for the glow and equalizer.
enum DominantColor {
    static func of(_ image: NSImage) -> Color {
        let size = 12
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return Theme.accent }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        var best: NSColor?
        var bestScore = -1.0
        for x in 0..<size {
            for y in 0..<size {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let score = Double(c.saturationComponent) * Double(c.brightnessComponent)
                if score > bestScore { bestScore = score; best = c }
            }
        }
        guard let best, bestScore > 0.08 else { return Color.white.opacity(0.8) }
        // Lift dark picks so the equalizer stays visible on black.
        let lifted = NSColor(hue: best.hueComponent, saturation: min(0.85, best.saturationComponent),
                             brightness: max(0.75, best.brightnessComponent), alpha: 1)
        return Color(nsColor: lifted)
    }
}

/// Covers drawn in code (gradients, soft shapes), for recordings and as a placeholder.
enum MockCovers {
    @MainActor static func tracks() -> [NowPlayingModule.Track] {
        [
            NowPlayingModule.Track(id: "t1", title: "Low Tide Lights", artist: "Ola Brenn", duration: 214,
                                   color: Color(hex: 0xFF7A45),
                                   cover: draw(base: (0xFF7A45, 0x7B2FF7), accent: 0xFFD166, seed: 1), source: .spotify,
                                   album: "Night Ferries"),
            NowPlayingModule.Track(id: "t2", title: "Glass Harbour", artist: "Nuri Kaas", duration: 188,
                                   color: Color(hex: 0x2EC4B6),
                                   cover: draw(base: (0x2EC4B6, 0x1B3A8C), accent: 0xB8F2E6, seed: 2), source: .music,
                                   album: "Coastlines"),
        ]
    }

    /// Invented lines (no real song's lyrics), timed for the two invented tracks.
    static func lyrics(for id: String) -> SyncedLyrics? {
        let lines = id == "t1"
            ? ["Harbour lights are blinking slow", "Every ferry knows the way", "Hold the rope and let it go",
               "Low tide lights, we stay", "Count the waves until the dawn", "Salt and neon on the bay"]
            : ["Glass on the water, glass in the sky", "Nothing to carry, nowhere to hide", "Turn with the current, turn with the tide",
               "Glass harbour, open wide"]
        let start: Double = id == "t1" ? 40 : 2
        return SyncedLyrics(lines: (0..<48).map { .init(time: start + Double($0) * 4, text: lines[$0 % lines.count]) })
    }

    static func placeholder() -> NSImage { draw(base: (0x3A3A44, 0x1C1C22), accent: 0x8A8A96, seed: 2) }

    static func draw(base: (UInt32, UInt32), accent: UInt32, seed: Int) -> NSImage {
        func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        }
        let size = NSSize(width: 320, height: 320)
        return NSImage(size: size, flipped: false) { rect in
            NSGradient(starting: color(base.0), ending: color(base.1))?.draw(in: rect, angle: seed == 1 ? -60 : 30)
            let circles: [(CGFloat, CGFloat, CGFloat, CGFloat)] = seed == 1
                ? [(0.68, 0.70, 0.30, 0.55), (0.25, 0.30, 0.22, 0.35), (0.80, 0.18, 0.10, 0.6)]
                : [(0.30, 0.65, 0.34, 0.45), (0.75, 0.30, 0.18, 0.5), (0.55, 0.85, 0.08, 0.7)]
            for (x, y, r, a) in circles {
                let circle = NSRect(x: rect.width * (x - r), y: rect.height * (y - r), width: rect.width * r * 2, height: rect.height * r * 2)
                NSGradient(colors: [color(accent, a), color(accent, 0)])?.draw(in: NSBezierPath(ovalIn: circle), relativeCenterPosition: .zero)
            }
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.height * (seed == 1 ? 0.12 : 0.9)),
                          radius: rect.width * 0.42, startAngle: seed == 1 ? 20 : 200, endAngle: seed == 1 ? 160 : 340)
            arc.lineWidth = 6
            color(0xFFFFFF, 0.55).setStroke()
            arc.stroke()
            return true
        }
    }
}
