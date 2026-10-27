import AppKit
import NotchCore
import Observation

/// Connects Jamie from onboarding: runs the bundled agent's `jamie_sync.py` through the same
/// login shell and `uv` as the Meeting module, and turns its lines into one state to show. The
/// first run opens the browser for Jamie's login.
@MainActor
@Observable
final class JamieConnect {
    enum Phase: Equatable {
        case idle
        case connecting
        /// Waiting for the login in the browser (its page, to open again).
        case login(URL?)
        case syncing(count: Int, title: String)
        case done(meetings: Int, hint: String?)
        case failed(String)

        /// Nothing came over: an empty account, or the wrong one.
        var isEmpty: Bool {
            if case .done(let meetings, let hint) = self { return meetings == 0 || hint == "empty_account" }
            return false
        }

        var isRunning: Bool {
            switch self {
            case .connecting, .login, .syncing: true
            default: false
            }
        }
    }

    private(set) var phase = Phase.idle
    /// Meetings came in (the app switches the Meeting agent on).
    @ObservationIgnored var onSynced: ((Int) -> Void)?
    @ObservationIgnored private var process: MeetingProcess?
    @ObservationIgnored private var count = 0

    private var directory: URL { Runtime.meetingAgentDir }
    private var log: URL { Brand.supportFolder.appending(path: "meeting-agent.log") }

    /// What stops the sync before it starts: no agent in this build, or no `uv`.
    var blocker: Blocker? {
        if MeetingAgentSetup.bundled == nil && !FileManager.default.fileExists(atPath: directory.appending(path: "jamie_sync.py").path) {
            return .noAgent
        }
        return MeetingAgentSetup.uvPath == nil ? .noUV : nil
    }

    enum Blocker { case noAgent, noUV }

    func connect() { run("exec uv run python jamie_sync.py") }

    /// Signs out of the Jamie account the sync used, then logs in again (the browser keeps its
    /// own Jamie session, so the user signs out there first).
    func useAnotherAccount() { run("uv run python jamie_sync.py --logout && exec uv run python jamie_sync.py") }

    func openLogin() {
        if case .login(let url?) = phase { NSWorkspace.shared.open(url) }
    }

    func cancel() {
        process?.terminate()
        process = nil
    }

    /// Screenshots: a state without running anything.
    func preview(_ phase: Phase) { self.phase = phase }

    private func run(_ command: String) {
        guard process == nil, blocker == nil else { return }
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        count = 0
        phase = .connecting
        process = MeetingProcess(command: command, directory: directory, log: log, onLine: { [weak self] line in
            Task { @MainActor in self?.handle(line) }
        }, onExit: { [weak self] in
            Task { @MainActor in self?.ended() }
        })
        if process == nil { phase = .failed("Couldn't start the Jamie sync") }
        Haptics.tick()
    }

    private func handle(_ line: Data) {
        switch MeetingLine.parse(line) {
        case .status("login", let url):
            phase = .login(url.flatMap(URL.init(string:)))
        case .synced(let title):
            count += 1
            phase = .syncing(count: count, title: title)
        case .syncDone(let meetings, let hint):
            phase = .done(meetings: meetings, hint: hint)
            if meetings > 0 { onSynced?(meetings) }
        case .error(let text):
            phase = .failed(text.replacingOccurrences(of: "jamie sync: ", with: ""))
        default:
            break
        }
    }

    private func ended() {
        process = nil
        // Ended without a summary line or an error: say so instead of spinning on.
        if phase.isRunning { phase = .failed("The sync stopped early; details in meeting-agent.log") }
    }
}
