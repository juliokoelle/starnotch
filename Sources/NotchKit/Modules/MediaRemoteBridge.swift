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
    /// The latest cover per track, kept across lines that leave it out.
    private(set) var artwork: (key: String, data: Data)?
    var onUpdate: (() -> Void)?

    private var process: Process?
    private var input: Pipe?
    private var buffer = Data()
    private var failures = 0
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

    /// Streaming, or about to be: false without the helper or after it failed three times.
    var isAvailable: Bool { Self.library != nil && failures < 3 }

    func start() {
        guard process == nil, let library = Self.library, failures < 3 else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.perl)
        process.arguments = ["-e", Self.loader, library.path, "starnotch_mr_stream"]
        let output = Pipe(), input = Pipe()
        process.standardOutput = output
        process.standardInput = input  // the helper exits when this closes, even after a crash
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in self?.receive(data) }
        }
        process.terminationHandler = { [weak self] ended in
            let status = ended.terminationStatus
            Task { @MainActor in self?.ended(status) }
        }
        do {
            try process.run()
            self.process = process
            self.input = input
        } catch {
            failures = 3
            Log.app.error("MediaRemote helper didn't start: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        restart?.cancel()
        guard let process else { return }
        self.process = nil
        try? input?.fileHandleForWriting.close()
        input = nil
        if process.isRunning { process.terminate() }
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        var changed = false
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let parsed = MediaSnapshot.parse(Data(line)) else { continue }
            failures = 0
            if case .playing(let snapshot) = parsed, let data = snapshot.artwork {
                artwork = (snapshot.trackKey, data)
            }
            current = parsed
            changed = true
        }
        if changed { onUpdate?() }
    }

    private func ended(_ status: Int32) {
        guard process != nil else { return }  // stopped on purpose
        process = nil
        input = nil
        current = nil
        failures += 1
        Log.app.error("MediaRemote helper ended (\(status, privacy: .public)), try \(self.failures, privacy: .public)")
        onUpdate?()
        guard failures < 3 else { return }
        restart = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.start()
        }
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
