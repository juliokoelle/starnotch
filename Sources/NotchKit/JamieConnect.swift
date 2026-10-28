import AppKit
import NotchCore
import Observation

/// Connects Jamie: runs the bundled agent's `jamie_sync.py` through the same login shell and `uv`
/// as the Meeting module, and turns its lines into one state to show. The first run opens the
/// browser for Jamie's login. The Meeting module owns the one sync of the app, so onboarding,
/// Settings and the notch show the same, and closing a window doesn't stop it.
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
    /// What stops the sync before it starts: no agent in this build, or no `uv` (`checkBlocker`).
    private(set) var blocker: Blocker?
    /// Every new phase (the Meeting module mirrors it in its line and reloads the agent when done).
    @ObservationIgnored var onPhase: ((Phase) -> Void)?
    /// Previews and sample data: a connect plays the phases without running anything.
    @ObservationIgnored var simulated = false { didSet { checkBlocker() } }
    @ObservationIgnored private var process: MeetingProcess?
    @ObservationIgnored private var count = 0

    private var directory: URL { Runtime.meetingAgentDir }
    private var log: URL { Brand.supportFolder.appending(path: "meeting-agent.log") }

    enum Blocker { case noAgent, noUV }

    init() { checkBlocker() }

    /// Looks again (uv may have been installed in Terminal meanwhile).
    func checkBlocker() {
        let found: Blocker? = if simulated {
            nil
        } else if MeetingAgentSetup.bundled == nil && !FileManager.default.fileExists(atPath: directory.appending(path: "jamie_sync.py").path) {
            .noAgent
        } else {
            MeetingAgentSetup.uvPath == nil ? .noUV : nil
        }
        if found != blocker { blocker = found }
    }

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

    private func set(_ next: Phase) {
        guard next != phase else { return }
        phase = next
        onPhase?(next)
    }

    private func run(_ command: String) {
        checkBlocker()
        guard process == nil, !phase.isRunning, blocker == nil else { return }
        Haptics.tick()
        if simulated { return simulate() }
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        count = 0
        set(.connecting)
        process = MeetingProcess(command: command, directory: directory, log: log, onLine: { [weak self] line in
            Task { @MainActor in self?.handle(line) }
        }, onExit: { [weak self] in
            Task { @MainActor in self?.ended() }
        })
        // A key, not a sentence: the row looks it up in the app's language.
        if process == nil { set(.failed("Couldn't start the Jamie sync")) }
    }

    /// The phases of a short sync, with made-up meetings; nothing runs, nothing is written.
    private func simulate() {
        set(.connecting)
        Task { [weak self] in
            for (index, title) in ["Kickoff", "Weekly with Lena", "Pricing review"].enumerated() {
                try? await Task.sleep(for: .milliseconds(700))
                self?.set(.syncing(count: index + 1, title: title))
            }
            try? await Task.sleep(for: .milliseconds(700))
            self?.set(.done(meetings: 3, hint: nil))
        }
    }

    private func handle(_ line: Data) {
        switch MeetingLine.parse(line) {
        case .status("login", let url):
            set(.login(url.flatMap(URL.init(string:))))
        case .synced(let title):
            count += 1
            set(.syncing(count: count, title: title))
        case .syncDone(let meetings, let hint):
            set(.done(meetings: meetings, hint: hint))
        case .error(let text):
            set(.failed(text.replacingOccurrences(of: "jamie sync: ", with: "")))
        default:
            break
        }
    }

    private func ended() {
        process = nil
        // Ended without a summary line or an error: say so instead of spinning on.
        if phase.isRunning { set(.failed("The sync stopped early; details in meeting-agent.log")) }
    }
}
