import Foundation
import IOKit
import IOKit.ps
import NotchCore

/// "Keep awake with the lid closed": runs the state machine (`LidAwake`) and its commands.
/// pmset runs through `sudo -n` off the main thread (on quit right away, so it is done before
/// the app is gone). A marker in the support folder exists while Starnotch keeps sleep off (from
/// just before pmset runs), and a watchdog brings sleep back when Starnotch dies with it there.
///
/// The state machine says what pmset should be; `apply` brings pmset there, one command at a
/// time, and looks at the state again after each one. So a switch, a safety stop or the timer that
/// lands while pmset runs never leaves sleep off behind a switch that says off.
///
/// The safety checks read the power source from IOKit and the thermal state: on every power
/// source change, on every thermal state change and at least once a minute.
@MainActor
final class LidAwakeController {
    enum Notice {
        /// Ended by itself: the time is up, the battery reached the floor or the Mac got too hot.
        case ended(LidAwake.Reason)
        /// Not switched on: the battery is at or under the floor, or the Mac is too hot.
        case refused(LidAwake.Reason)
        /// Sleep was already off before (set outside Starnotch): left alone.
        case alreadyOff
        case failed
        /// Sleep didn't come back after it ended: tried again at the next check.
        case stillOff
        /// The rule didn't go in, or `sudo -n` doesn't accept it (not a cancel in the dialog).
        case ruleFailed

        var isEnd: Bool { if case .ended = self { true } else { false } }
    }

    enum RuleInstall { case installed, cancelled, failed }

    private var machine = LidAwake()
    private let marker: URL
    private var timer: Task<Void, Never>?
    /// What Starnotch last set pmset to (`disablesleep 1` = true).
    private var applied = false
    /// The one pmset run in flight; a second change waits for it instead of running beside it.
    private var applying: Task<Void, Never>?
    private(set) var busy = false
    /// The state changed, or `busy` (asking for the password, running pmset).
    var onChange: ((LidAwake.State, Bool) -> Void)?
    var onNotice: ((Notice) -> Void)?
    /// Asks for the password once and installs the rule; `.installed` when `sudo -n` works afterwards.
    var installRule: (() async -> RuleInstall)?
    private var thermalObserver: NSObjectProtocol?
    /// The longest the safety checks wait while on, in case a notification comes late.
    private static let checkEvery: TimeInterval = 60

    init(marker: URL) {
        self.marker = marker
        thermalObserver = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    /// The battery read fresh from IOKit (nil without one: no floor) and the thermal state.
    private func readings() -> LidAwakeReadings {
        LidAwakeReadings(battery: BatteryMonitor.read(), onBattery: Self.onBattery(), thermal: ProcessInfo.processInfo.thermalState)
    }

    var state: LidAwake.State { machine.state }

    /// The user picked a time and a floor (also while on: then only the end moves).
    func switchOn(_ limit: LidAwakeLimit, floor: Int) {
        guard !busy else { return }
        setBusy(true)
        Task {
            await switchOn(limit, floor: floor, ruleInstalled: await Self.ruleWorks())
            schedule()
            setBusy(false)
        }
    }

    /// Every await comes before the one `handle` that may switch on, and the readings are taken
    /// right there: a drop in charge or a rise in heat during the checks is never missed
    /// (`check` ignores it while off).
    private func switchOn(_ limit: LidAwakeLimit, floor: Int, ruleInstalled: Bool) async {
        var ruleInstalled = ruleInstalled
        // When it may not run the last `handle` says why; the password isn't asked for first.
        if !ruleInstalled, LidAwake.refusal(floor: floor, readings()) == nil {
            switch await installRule?() ?? .cancelled {
            case .installed: ruleInstalled = true
            case .cancelled: return
            case .failed: onNotice?(.ruleFailed); return
            }
        }
        if !machine.isOn, ruleInstalled, LidAwake.refusal(floor: floor, readings()) == nil, !applied, await Self.sleepDisabledAlready(), !applied,
           !FileManager.default.fileExists(atPath: marker.path) {
            // Someone else switched sleep off: switching it back on later would undo their choice.
            onNotice?(.alreadyOff)
            return
        }
        await perform(machine.handle(.switchOn(limit, floor: floor, readings: readings(), ruleInstalled: ruleInstalled), now: Date()))
    }

    func switchOff() {
        guard machine.isOn else { return }
        Task { await perform(machine.handle(.switchOff, now: Date())) }
    }

    /// Before the rule goes: sleep comes back while `sudo -n` still may run pmset.
    func switchOffAndWait() async {
        if machine.isOn { await perform(machine.handle(.switchOff, now: Date())) }
    }

    /// The power source or the heat changed: the floor and the heat are checked again. Off with
    /// sleep still off (pmset 0 failed), pmset 0 is tried again.
    func check() {
        if !machine.isOn && applied { Task { await retry() } }
        guard machine.isOn else { return }
        Task { await perform(machine.handle(.check(readings()), now: Date())) }
    }

    /// The app quits: sleep comes back before it is gone. A pmset still running finishes first
    /// (`runPmset` takes turns), so this one is always the last word.
    func quit() {
        let action = machine.handle(.quit, now: Date())
        guard action != .none || applied || applying != nil || FileManager.default.fileExists(atPath: marker.path) else { return }
        timer?.cancel()
        if Self.runPmset(false) { try? FileManager.default.removeItem(at: marker) }
    }

    /// At launch: a marker left from a crash or a forced quit means sleep is still off.
    func cleanUpAfterLaunch() {
        guard LidAwake.needsCleanup(markerExists: FileManager.default.fileExists(atPath: marker.path)) else { return }
        let marker = marker
        Task {
            let done = await Task.detached(priority: .utility) { Self.runPmset(false) }.value
            if done { try? FileManager.default.removeItem(at: marker) }
            Log.app.info("Lid closed: sleep switched back on after launch (\(done ? "done" : "failed", privacy: .public))")
        }
    }

    private func perform(_ action: LidAwake.Action) async {
        switch action {
        case .none, .installRule:
            break
        case .refused(let reason):
            onNotice?(.refused(reason))
        case .enable:
            await apply()
        case .disable(let reason):
            timer?.cancel()
            await apply()
            if applied && !machine.isOn {
                // pmset 0 failed: say so, and try again at the next check.
                onNotice?(.stillOff)
                schedule()
            } else if !applied && reason != .user && reason != .quit {
                onNotice?(.ended(reason))
                // A Mac that is already closed may stay awake once sleep is allowed again: ask
                // for sleep (keep awake's assertion is released with the notice).
                if Self.closedLidSleeps() { await Self.sleepNow() }
            }
        }
        onChange?(machine.state, busy)
    }

    /// Off with sleep still off (pmset 0 failed): pmset 0 again, then the next try in a minute or,
    /// once it ran, sleep for a closed lid.
    private func retry() async {
        await apply()
        if applied && !machine.isOn { schedule() } else if !applied && Self.closedLidSleeps() { await Self.sleepNow() }
    }

    /// Brings pmset to the state machine: one run at a time, and after each the state is read
    /// again, so the last change wins whatever order the events came in. A caller while a run is
    /// in flight waits for that run, which then also covers its change.
    private func apply() async {
        if let applying { return await applying.value }
        let marker = marker
        let run = Task { [weak self] in
            while let self, self.applied != self.machine.isOn {
                let want = self.machine.isOn
                if want {
                    // The marker (with this pid) goes first, then the watchdog: a crash or a forced
                    // quit at any point from here on still gets sleep back.
                    try? FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? String(ProcessInfo.processInfo.processIdentifier).write(to: marker, atomically: true, encoding: .utf8)
                }
                let done = await Task.detached(priority: .userInitiated) {
                    if want { Self.startWatchdog(marker: marker) }
                    return Self.runPmset(want)
                }.value
                if done {
                    self.applied = want
                    if !want { try? FileManager.default.removeItem(at: marker) }
                } else if want {
                    // Sleep stayed on: no marker (the watchdog then ends by itself).
                    try? FileManager.default.removeItem(at: marker)
                    if self.machine.isOn {
                        _ = self.machine.handle(.failed, now: Date())
                        self.timer?.cancel()
                        self.onNotice?(.failed)
                    }
                } else {
                    // Sleep didn't come back: the marker stays, so the next launch tries again.
                    break
                }
            }
            self?.applying = nil
        }
        applying = run
        await run.value
    }

    /// Wakes at the limit, and at least once a minute while on to check the battery and the heat
    /// again; a wake before the limit sleeps again for the rest. Off with sleep still off (pmset 0
    /// failed), it tries pmset 0 again once a minute.
    private func schedule() {
        timer?.cancel()
        guard machine.isOn || applied else { return }
        let wait = min(Self.checkEvery, machine.remaining(now: Date()) ?? Self.checkEvery)
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            guard self.machine.isOn else { return await self.retry() }
            let action = self.machine.handle(.check(self.readings()), now: Date())
            if action == .none { self.schedule() } else { await self.perform(action) }
        }
    }

    private func setBusy(_ busy: Bool) {
        self.busy = busy
        onChange?(machine.state, busy)
    }

    /// pmset runs take turns, also the one at quit on the main thread.
    nonisolated private static let pmsetTurn = NSLock()

    nonisolated private static func runPmset(_ disableSleep: Bool) -> Bool {
        pmsetTurn.withLock {
            SetupActions.processRunner(LidAwakeCommands.sudo, LidAwakeCommands.sudoArguments(disableSleep), [:]).status == 0
        }
    }

    /// Runs on IOKit's battery, not the power adapter (also when the battery can't be read).
    nonisolated private static func onBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }

    /// The lid is closed and that would put the Mac to sleep (no external display on power), as
    /// the root domain says.
    nonisolated static func closedLidSleeps() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        func flag(_ key: String) -> Bool {
            IORegistryEntryCreateCFProperty(root, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool == true
        }
        return flag("AppleClamshellState") && flag("AppleClamshellCausesSleep")
    }

    /// `pmset sleepnow` needs no root.
    nonisolated private static func sleepNow() async {
        await Task.detached(priority: .userInitiated) {
            _ = SetupActions.processRunner(LidAwakeCommands.pmset, ["sleepnow"], [:])
        }.value
    }

    /// Starts the watchdog (`LidAwakeCommands.watchdogArguments`) in its own session, so it
    /// outlives Starnotch; the shell only puts it in the background and returns at once.
    nonisolated private static func startWatchdog(marker: URL) {
        let arguments = ["/bin/sh"] + LidAwakeCommands.watchdogArguments(pid: ProcessInfo.processInfo.processIdentifier, marker: marker.path)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var files: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&files)
        defer { posix_spawn_file_actions_destroy(&files) }
        for fd: Int32 in 0...2 { posix_spawn_file_actions_addopen(&files, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0) }
        let argv = arguments.map { strdup($0) } + [nil]
        let environment = [strdup("PATH=/usr/bin:/bin:/usr/sbin:/sbin"), nil]
        defer { (argv + environment).forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, "/bin/sh", &files, &attributes, argv, environment) == 0 else {
            Log.app.error("Lid closed: the watchdog didn't start")
            return
        }
        waitpid(pid, nil, 0)
    }

    nonisolated private static func ruleWorks() async -> Bool {
        await Task.detached(priority: .userInitiated) {
            SetupActions.processRunner(LidAwakeCommands.sudo, LidAwakeCommands.checkArguments, [:]).status == 0
        }.value
    }

    nonisolated private static func sleepDisabledAlready() async -> Bool {
        await Task.detached(priority: .userInitiated) {
            LidAwakeCommands.sleepDisabled(pmsetOutput: SetupActions.processRunner(LidAwakeCommands.pmset, ["-g"], [:]).output) == true
        }.value
    }
}
