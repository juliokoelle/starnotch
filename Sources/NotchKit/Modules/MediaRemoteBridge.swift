import AppKit
import Foundation
import NotchCore

/// What plays system-wide, from any app, through MediaRemote. Since macOS 15.4 MediaRemote
/// answers only Apple-signed processes, so the app runs `/usr/bin/perl`, which loads the bundled
/// helper library (helpers/mediaremote) and streams one JSON line per change. Controls run the
/// helper once per command. Everything stays on this Mac.
///
/// When the helper is missing (a `swift run` build) or stops working (a future macOS closes the
/// door), `isAvailable` turns false and Now Playing falls back to AppleScript for Spotify and Music.
@MainActor
final class MediaRemoteBridge {
    /// The newest report: nil until the first line, `.nothing` while nothing plays.
    private(set) var current: MediaSnapshot.Line?
    /// The cover sent last, kept for the lines that leave its data out.
    private var artwork = MediaArtwork()
    var onUpdate: (() -> Void)?

    private var stream: LineProcess?
    private var startedAt = Date()
    private var restarts = HelperRestarts()
    private var restart: Task<Void, Never>?

    /// The helper library inside the app.
    nonisolated static let library: URL? = {
        guard let url = Bundle.main.privateFrameworksURL?.appending(path: "libStarnotchMediaRemote.dylib"),
              FileManager.default.fileExists(atPath: url.path),
              FileManager.default.isExecutableFile(atPath: perl) else { return nil }
        return url
    }()

    nonisolated static let perl = "/usr/bin/perl"
    /// Loads the library and calls one of its functions; perl itself does nothing else.
    private static let loader = """
    use DynaLoader; my $h = DynaLoader::dl_load_file($ARGV[0], 0) or exit 3; \
    my $s = DynaLoader::dl_find_symbol($h, $ARGV[1]) or exit 4; \
    DynaLoader::dl_install_xsub("main::run", $s); &main::run;
    """

    /// The helper gave up (it failed three times); for the copy that promises any app.
    private(set) static var gaveUp = false
    /// The system-wide source works on this Mac, as far as anyone knows yet.
    static var isUsable: Bool { library != nil && !gaveUp }

    /// Streaming, or about to be: false without the helper or after it failed three times.
    var isAvailable: Bool { Self.library != nil && !restarts.gaveUp }

    func start() {
        guard stream == nil, let library = Self.library, !restarts.gaveUp else { return }
        restart?.cancel()
        restart = nil
        let stream = LineProcess(executable: URL(fileURLWithPath: Self.perl),
                                 arguments: ["-e", Self.loader, library.path, "starnotch_mr_stream"])
        do {
            try stream.start(queue: .main, onLine: { [weak self] line in
                MainActor.assumeIsolated { self?.receive(line, from: stream) }
            }, onExit: { [weak self] status in
                MainActor.assumeIsolated { self?.ended(status, from: stream) }
            })
            self.stream = stream
            startedAt = Date()
        } catch {
            giveUp()
            Log.app.error("MediaRemote helper didn't start: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Stops streaming (Music switched off); `start()` brings it back.
    func stop() {
        restart?.cancel()
        restart = nil
        guard let stream else { return }
        self.stream = nil
        stream.stop()
        current = nil
    }

    private func receive(_ line: Data, from stream: LineProcess) {
        guard stream === self.stream, let parsed = MediaSnapshot.parse(line) else { return }
        if case .playing(let snapshot) = parsed { artwork.remember(snapshot) }
        current = parsed
        onUpdate?()
    }

    /// The cover for this report, also when its line left the data out (same cover as before).
    func artwork(for snapshot: MediaSnapshot) -> Data? { artwork.artwork(for: snapshot) }

    private func ended(_ status: Int32, from stream: LineProcess) {
        guard stream === self.stream else { return }  // stopped on purpose
        self.stream = nil
        current = nil
        let again = restarts.ended(after: Date().timeIntervalSince(startedAt))
        Log.app.error("MediaRemote helper ended (\(status, privacy: .public)), failures \(self.restarts.failures, privacy: .public)")
        if !again { giveUp() }
        onUpdate?()
        guard again else { return }
        restart = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.start()
        }
    }

    private func giveUp() {
        restarts.failedToStart()
        Self.gaveUp = true
    }

    /// The commands MediaRemote knows (`MRCommand`).
    enum Command: Int {
        case play = 0, pause = 1, togglePlayPause = 2, next = 4, previous = 5
    }

    func send(_ command: Command) {
        run(environment: ["STARNOTCH_MR_COMMAND": String(command.rawValue)])
    }

    func seek(to seconds: Double) {
        run(environment: ["STARNOTCH_MR_SEEK": String(format: "%.3f", seconds)])
    }

    private func run(environment: [String: String]) {
        guard let library = Self.library else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.perl)
        process.arguments = ["-e", Self.loader, library.path, "starnotch_mr_control"]
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
