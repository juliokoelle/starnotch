import AppKit
import NotchCore
import Observation

/// Connects Jamie: runs the bundled agent's `jamie_sync.py` through the same login shell and `uv`
/// as the Meeting module, and turns its lines into one state to show. The first run opens the
/// browser for Jamie's login. The Meeting module owns the one sync of the app, so onboarding,
/// Settings and the notch show the same, and closing a window doesn't stop it. While a login is
/// saved it also syncs on its own (`JamieSyncSchedule`), without ever opening the browser.
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
    /// When the last sync finished well (after a relaunch, the time of Jamie's state file), and how
    /// many meetings it wrote (unknown after a relaunch).
    private(set) var lastSynced: Date?
    private(set) var lastNew: Int?
    /// The running (or last) sync was started by the schedule, not a button.
    private(set) var automatic = false
    /// The last sync wrote new or changed meetings, so running agents re-read the memory.
    @ObservationIgnored private(set) var wroteMeetings = false
    /// The ends of today's calls and meetings with others (the Calendar module's events).
    @ObservationIgnored var meetingEnds: () -> [Date] = { [] }
    /// Every new phase (the Meeting module mirrors it in its line and reloads the agent when done).
    @ObservationIgnored var onPhase: ((Phase) -> Void)?
    /// Previews and sample data: a connect plays the phases without running anything.
    @ObservationIgnored var simulated = false { didSet { checkBlocker() } }
    @ObservationIgnored private var process: MeetingProcess?
    @ObservationIgnored private var count = 0
    @ObservationIgnored private var schedule = JamieSyncSchedule(connected: false, launched: Date())
    /// Jamie asked for a new login during a sync of its own: no more until the user connects again.
    @ObservationIgnored private var loginLost = false
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    private var directory: URL { Runtime.meetingAgentDir }
    private var log: URL { Brand.supportFolder.appending(path: "meeting-agent.log") }
    // Where jamie_sync.py keeps its login and the fingerprints it writes at the end of each sync. The sidecar
    // always uses Application Support/Starnotch, so a build with another SUPPORT_FOLDER won't find them.
    private var tokenFile: URL { Brand.supportFolder.appending(path: "jamie-oauth.json") }
    private var stateFile: URL { Brand.supportFolder.appending(path: "memory/jamie-sync.state") }

    /// A Jamie login is saved (Connect has worked once and nobody signed out). The file alone isn't one:
    /// registering the client writes it before the browser login, which may never have finished.
    var hasLogin: Bool {
        guard let data = try? Data(contentsOf: tokenFile),
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return saved["tokens"] is [String: Any]
    }

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

    func connect() {
        loginLost = false
        run("exec uv run python jamie_sync.py")
    }

    /// Signs out of the Jamie account the sync used, then logs in again (the browser keeps its
    /// own Jamie session, so the user signs out there first).
    func useAnotherAccount() {
        loginLost = false
        run("uv run python jamie_sync.py --logout && exec uv run python jamie_sync.py")
    }

    /// Starts the syncs of its own: a look at the schedule every 30 seconds, and after a wake.
    func startAutomatic() {
        guard ticker == nil, !simulated else { return }
        lastSynced = (try? FileManager.default.attributesOfItem(atPath: stateFile.path))?[.modificationDate] as? Date
        schedule = JamieSyncSchedule(connected: false, launched: Date(), lastSuccess: lastSynced)
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.syncIfDue(.timer)
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            // The network needs a moment after waking.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(15))
                self?.syncIfDue(.wake)
            }
        }
    }

    /// Syncs in the background when the schedule says so (one sync at a time, never the browser). Only the
    /// newest ten meetings: an unchanged one still costs a request, and the buttons sync the full 50.
    func syncIfDue(_ trigger: JamieSyncSchedule.Trigger) {
        guard ticker != nil else { return }
        schedule.connected = !loginLost && hasLogin
        schedule.meetingEnds = meetingEnds()
        guard schedule.shouldSync(trigger, now: Date()) else { return }
        run("exec uv run python jamie_sync.py --no-login --limit 10", automatic: true)
    }

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
        if case .failed = next { schedule.failed(at: Date()) }  // the next sync of its own waits a while
        phase = next
        onPhase?(next)
    }

    private func run(_ command: String, automatic: Bool = false) {
        checkBlocker()
        guard process == nil, !phase.isRunning, blocker == nil else { return }
        if !automatic { Haptics.tick() }
        if simulated { return simulate() }
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        count = 0
        self.automatic = automatic
        wroteMeetings = false
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
        let parsed = MeetingLine.parse(line)
        switch parsed {
        case .status("login", let url):
            set(.login(url.flatMap(URL.init(string:))))
        case .status("login_required", _):
            loginLost = true
            set(.failed("Jamie signed you out; connect again to keep your meetings in sync"))
        case .synced(let title):
            count += 1
            set(.syncing(count: count, title: title))
        case .syncDone(let meetings, let updated, let hint):
            let now = Date()
            lastSynced = now
            lastNew = updated
            wroteMeetings = parsed?.reloadsMemory ?? false
            schedule.succeeded(at: now)
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
