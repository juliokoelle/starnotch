import AppKit
import NotchCore
import Observation
import SwiftUI

/// Now Playing in three stages: ears (cover, equalizer, no text), hover (cover, title, one play
/// button, hairline progress), panel (cover with source badge and glow, scrubber, controls).
/// The cover's dominant color is the only extra color. Live data comes from Spotify and Music
/// via AppleScript (`PlayerBridge`); browsers come later.
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
    }

    let kind = ModuleKind.nowPlaying
    let symbol = ModuleSymbols.symbol(.nowPlaying)

    private(set) var track: Track?
    private(set) var isPlaying = false
    private(set) var position: TimeInterval = 0
    /// +1 next, -1 previous: content slides that way.
    private(set) var direction: CGFloat = 1
    let cast: AvatarCast
    /// Output device and volume (CoreAudio).
    let output = AudioOutput()
    /// The output list, floating over the card. While it shows, the island holds its lock so
    /// it doesn't collapse when the pointer wanders; a click outside closes the list.
    var showsOutputs = false {
        didSet {
            guard showsOutputs != oldValue else { return }
            if showsOutputs {
                outputLock = IslandLock.shared.acquire("output list") { [weak self] in
                    withAnimation(Theme.snappy) { self?.showsOutputs = false }
                }
            } else if let outputLock {
                self.outputLock = nil
                IslandLock.shared.release(outputLock)
            }
        }
    }
    @ObservationIgnored private var outputLock: Int?
    @ObservationIgnored var onTrackChange: ((Track) -> Void)?

    @ObservationIgnored private var mockTracks: [Track] = []
    @ObservationIgnored private var mockIndex = 0
    @ObservationIgnored private var clock: Task<Void, Never>?
    @ObservationIgnored private var live = false
    @ObservationIgnored private var lastStatus: PlayerStatus?

    init(cast: AvatarCast) {
        self.cast = cast
    }

    // MARK: Sources

    /// Recordings: two invented tracks with covers drawn in code.
    func start() {
        mockTracks = MockCovers.tracks()
        track = mockTracks[0]
        isPlaying = true
        position = 47
        clock?.cancel()
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.isPlaying, let track = self.track else { continue }
                self.position += 0.5
                if self.position >= track.duration { self.next() }
            }
        }
    }

    /// Spotify and Music, polled every 1.5 s while one of them runs. Nothing is sent to an app
    /// that isn't running, so the Automation prompt appears only once the user plays music.
    func startLive() {
        live = true
        clock?.cancel()
        clock = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .milliseconds(1500))
            }
        }
    }

    private func poll() async {
        guard let status = PlayerBridge.status() else {
            if track != nil { withAnimation(Theme.close) { track = nil; isPlaying = false } }
            lastStatus = nil
            return
        }
        let changed = status.trackID != lastStatus?.trackID
        lastStatus = status
        position = status.position
        if isPlaying != status.isPlaying { withAnimation(Theme.snappy) { isPlaying = status.isPlaying } }
        guard changed else { return }
        let cover = await PlayerBridge.artwork(for: status) ?? MockCovers.placeholder()
        let new = Track(id: status.trackID, title: status.title, artist: status.artist, duration: status.duration,
                        color: DominantColor.of(cover), cover: cover, source: status.source)
        let hadTrack = track != nil
        withAnimation(Theme.open) { track = new }
        if hadTrack { onTrackChange?(new) }
    }

    // MARK: Controls

    func togglePlay() {
        Haptics.tick()
        if live, let source = track?.source { PlayerBridge.send("playpause", to: source) }
        withAnimation(Theme.snappy) { isPlaying.toggle() }
    }

    func next() { step(1) }
    func previous() { step(-1) }

    private func step(_ delta: Int) {
        Haptics.tick()
        direction = CGFloat(delta)
        if live {
            if let source = track?.source { PlayerBridge.send(delta > 0 ? "next track" : "previous track", to: source) }
            return  // the next poll picks up the new track
        }
        guard !mockTracks.isEmpty else { return }
        mockIndex = (mockIndex + delta + mockTracks.count) % mockTracks.count
        withAnimation(Theme.open) {
            track = mockTracks[mockIndex]
            position = 0
            isPlaying = true
        }
        if let track { onTrackChange?(track) }
    }

    // MARK: NotchModule

    /// Beside the notch while music plays; agents at work keep the ears (they show a small
    /// equalizer next to their count instead).
    var ambientPriority: Int { isPlaying && track != nil ? 15 : 0 }

    func setExpanded(_ expanded: Bool) {
        if !expanded { showsOutputs = false }
    }

    func handleBack() -> Bool {
        guard showsOutputs else { return false }
        withAnimation(Theme.snappy) { showsOutputs = false }
        return true
    }

    func leadingEar(peek: Bool) -> AnyView {
        guard let track else { return AnyView(EmptyView()) }
        return AnyView(CoverView(track: track, size: peek ? 26 : 20, badge: peek)
            .id(track.id)
            .transition(.blurSlide(scale: 0.8)))
    }

    func trailingEar(peek: Bool) -> AnyView {
        guard let track else { return AnyView(EmptyView()) }
        return AnyView(Equalizer(color: track.color, playing: isPlaying, height: peek ? 14 : 12))
    }

    /// Hover: title, one play button, hairline progress. No artist, no other controls.
    func peekLine() -> AnyView {
        AnyView(VStack(spacing: 7) {
            HStack(spacing: 8) {
                Text(track?.title ?? "Nothing playing")
                    .font(Theme.font(13, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
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
        .transition(.blurSlide(x: 14 * direction)))
    }

    func body() -> AnyView { AnyView(NowPlayingBody(module: self)) }

    func primaryAction() { togglePlay() }
}

private struct NowPlayingBody: View {
    let module: NowPlayingModule

    var body: some View {
        Group {
            if let track = module.track {
                player(track)
                    .frame(height: 156)
                    .overlayPreferenceValue(OutputButtonAnchor.self) { anchor in
                        GeometryReader { proxy in
                            if module.showsOutputs, let anchor {
                                OutputPopover(output: module.output, button: proxy[anchor], in: proxy.size) {
                                    withAnimation(Theme.snappy) { module.showsOutputs = false }
                                }
                            }
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                HStack(spacing: 14) {
                    Image(systemName: "music.note")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 56, height: 56)
                        .background(Theme.cardHover, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Nothing playing").font(Theme.font(14, .semibold)).foregroundStyle(Theme.textPrimary)
                        Text("Play something in Spotify or Music and it shows up here.")
                            .font(Theme.font(12)).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 22)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
    }

    private func player(_ track: NowPlayingModule.Track) -> some View {
        ZStack(alignment: .topTrailing) {
            // Sized for the narrow panel: cover, text and controls fit without clipping.
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(track.color.opacity(0.55))
                        .frame(width: 80, height: 80)
                        .blur(radius: 22)
                    CoverView(track: track, size: 80, badge: true)
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
                }
                .id(track.id)
                .transition(.blurSlide(x: 40 * module.direction, scale: 0.92))

                VStack(alignment: .leading, spacing: 0) {
                    Group {
                        Text(track.title)
                            .font(Theme.font(16, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(track.artist)
                            .font(Theme.font(13))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.top, 2)
                    }
                    .lineLimit(1)
                    // Room for the character in the corner: long titles end in … before it.
                    .padding(.trailing, 58)
                    .id(track.id)
                    .transition(.blurSlide(x: 24 * module.direction))

                    Scrubber(position: module.position, duration: track.duration)
                        .padding(.top, 14)

                    HStack(spacing: 6) {
                        control("backward.fill", size: 13, label: "Previous") { module.previous() }
                        control(module.isPlaying ? "pause.fill" : "play.fill", size: 17,
                                label: module.isPlaying ? "Pause" : "Play") { module.togglePlay() }
                            .contentTransition(.symbolEffect(.replace))
                        control("forward.fill", size: 13, label: "Next") { module.next() }
                        Spacer(minLength: 8)
                        VolumeSlider(output: module.output)
                        OutputButton(output: module.output, open: Binding(get: { module.showsOutputs },
                                                                          set: { module.showsOutputs = $0 }))
                    }
                    .padding(.top, 8)
                    .padding(.leading, -8)
                }
                .frame(maxWidth: 300, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(.leading, 16)
            .padding(.trailing, 12)
            .frame(maxHeight: .infinity)

            // The main character listens along with headphones, in the top corner beside the
            // title, so it never covers the controls in the narrow panel.
            AvatarView(character: module.cast.main, mood: .music, height: 54,
                       colorway: module.cast.colorway, emergeOnAppear: false)
                .frame(width: 62, alignment: .top)
                .padding(.top, 12)
                .padding(.trailing, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .animation(Theme.open, value: track.id)
    }

    private func control(_ symbol: String, size: CGFloat, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(label)
    }
}

/// Thin scrubber: the played part in white, times small and quiet, remaining time negative.
private struct Scrubber: View {
    let position: TimeInterval
    let duration: TimeInterval

    var body: some View {
        VStack(spacing: 5) {
            GeometryReader { proxy in
                let fraction = duration > 0 ? min(1, position / duration) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.14))
                    Capsule().fill(Color.white.opacity(0.85)).frame(width: proxy.size.width * fraction)
                }
            }
            .frame(height: 3)
            HStack {
                Text(Self.time(position))
                Spacer()
                Text("-" + Self.time(max(0, duration - position)))
            }
            .font(Theme.font(11.5).monospacedDigit())
            .foregroundStyle(Theme.textTertiary)
        }
        .animation(.linear(duration: 0.5), value: position)
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
                if badge, let source = track.source, let icon = PlayerBridge.icon(for: source) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: max(12, size * 0.24), height: max(12, size * 0.24))
                        .shadow(color: .black.opacity(0.5), radius: 2)
                        .offset(x: size * 0.06, y: size * 0.06)
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
            return (player state as string) & "||" & (name of t) & "||" & (artist of t) & "||" & (duration of t) & "||" & (player position) & "||" & \(artwork) & "||" & \(id)
        end tell
        """
        guard let reply = run(script) else { return nil }
        return PlayerStatus.parse(reply, source: source)
    }

    static func send(_ command: String, to source: PlayerStatus.Source) {
        guard isRunning(source), let app = names[source] else { return }
        _ = run("tell application \"\(app)\" to \(command)")
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
        guard let id = bundleIDs[source], let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private static func run(_ source: String) -> String? {
        let script = scripts[source] ?? NSAppleScript(source: source)
        scripts[source] = script
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
                                   cover: draw(base: (0xFF7A45, 0x7B2FF7), accent: 0xFFD166, seed: 1), source: .spotify),
            NowPlayingModule.Track(id: "t2", title: "Glass Harbour", artist: "Nuri Kaas", duration: 188,
                                   color: Color(hex: 0x2EC4B6),
                                   cover: draw(base: (0x2EC4B6, 0x1B3A8C), accent: 0xB8F2E6, seed: 2), source: .music),
        ]
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
