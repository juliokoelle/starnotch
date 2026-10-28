import Foundation
import NotchCore

/// "Keep awake with the lid closed": runs the state machine (`LidAwake`) and its commands.
/// pmset runs through `sudo -n` off the main thread (on quit right away, so it is done before
/// the app is gone). A marker in the support folder exists exactly while Starnotch keeps sleep off.
///
/// The state machine says what pmset should be; `apply` brings pmset there, one command at a
/// time, and looks at the state again after each one. So a switch, an unplug or the timer that
/// lands while pmset runs never leaves sleep off behind a switch that says off.
@MainActor
final class LidAwakeController {
    enum Notice {
        /// Ended by itself: unplugged or the time is up.
        case ended(LidAwake.Reason)
        case needsPower
        /// Sleep was already off before (set outside Starnotch): left alone.
        case alreadyOff
        case failed
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
    /// On the power adapter right now.
    var onPower: () -> Bool = { false }

    init(marker: URL) { self.marker = marker }

    var state: LidAwake.State { machine.state }

    /// The user picked a time (also while on: then only the end moves).
    func switchOn(_ limit: LidAwakeLimit) {
        guard !busy else { return }
        setBusy(true)
        Task {
            await switchOn(limit, ruleInstalled: await Self.ruleWorks())
            schedule()
            setBusy(false)
        }
    }

    /// Every await comes before the one `handle` that may switch on, and the power is read right
    /// there: an unplug during the checks is never missed (`powerChanged` ignores it while off).
    private func switchOn(_ limit: LidAwakeLimit, ruleInstalled: Bool) async {
        var ruleInstalled = ruleInstalled
        // Off the adapter the last `handle` says so; the password isn't asked for first.
        if !ruleInstalled, onPower() {
            switch await installRule?() ?? .cancelled {
            case .installed: ruleInstalled = true
            case .cancelled: return
            case .failed: onNotice?(.ruleFailed); return
            }
        }
        if !machine.isOn, ruleInstalled, onPower(), !applied, await Self.sleepDisabledAlready(), !applied,
           !FileManager.default.fileExists(atPath: marker.path) {
            // Someone else switched sleep off: switching it back on later would undo their choice.
            onNotice?(.alreadyOff)
            return
        }
        await perform(machine.handle(.switchOn(limit, onPower: onPower(), ruleInstalled: ruleInstalled), now: Date()))
    }

    func switchOff() {
        guard machine.isOn else { return }
        Task { await perform(machine.handle(.switchOff, now: Date())) }
    }

    /// Before the rule goes: sleep comes back while `sudo -n` still may run pmset.
    func switchOffAndWait() async {
        if machine.isOn { await perform(machine.handle(.switchOff, now: Date())) }
    }

    func powerChanged(_ onPower: Bool) {
        guard machine.isOn else { return }
        Task { await perform(machine.handle(.power(onPower: onPower), now: Date())) }
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
        case .needsPower:
            onNotice?(.needsPower)
        case .enable:
            await apply()
        case .disable(let reason):
            timer?.cancel()
            await apply()
            if reason == .unplugged || reason == .timeUp { onNotice?(.ended(reason)) }
        }
        onChange?(machine.state, busy)
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
                let done = await Task.detached(priority: .userInitiated) { Self.runPmset(want) }.value
                if done {
                    self.applied = want
                    if want {
                        try? FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try? Date().ISO8601Format().write(to: marker, atomically: true, encoding: .utf8)
                    } else {
                        try? FileManager.default.removeItem(at: marker)
                    }
                } else if want {
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

    /// Wakes at the limit; a wake a moment early sleeps again for the rest.
    private func schedule() {
        timer?.cancel()
        guard let until = machine.until else { return }
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, until.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            let action = self.machine.handle(.tick, now: Date())
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
