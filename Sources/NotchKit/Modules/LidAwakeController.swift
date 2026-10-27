import Foundation
import NotchCore

/// "Keep awake with the lid closed": runs the state machine (`LidAwake`) and its commands.
/// pmset runs through `sudo -n` off the main thread (on quit right away, so it is done before
/// the app is gone). A marker in the support folder exists exactly while Starnotch keeps sleep off.
@MainActor
final class LidAwakeController {
    enum Notice {
        /// Ended by itself: unplugged or the time is up.
        case ended(LidAwake.Reason)
        case needsPower
        /// Sleep was already off before (set outside Starnotch): left alone.
        case alreadyOff
        case failed

        var isEnd: Bool { if case .ended = self { true } else { false } }
    }

    private var machine = LidAwake()
    private let marker: URL
    private var timer: Task<Void, Never>?
    private(set) var busy = false
    /// The state changed, or `busy` (asking for the password, running pmset).
    var onChange: ((LidAwake.State, Bool) -> Void)?
    var onNotice: ((Notice) -> Void)?
    /// Asks for the password once and installs the rule; true when `sudo -n` works afterwards.
    var installRule: (() async -> Bool)?
    /// On the power adapter right now.
    var onPower: () -> Bool = { false }

    init(marker: URL) { self.marker = marker }

    var state: LidAwake.State { machine.state }

    /// The user picked a time (also while on: then only the end moves).
    func switchOn(_ limit: LidAwakeLimit) {
        guard !busy else { return }
        setBusy(true)
        Task {
            var action = machine.handle(.switchOn(limit, onPower: onPower(), ruleInstalled: await Self.ruleWorks()), now: Date())
            if action == .installRule, await installRule?() == true {
                action = machine.handle(.switchOn(limit, onPower: onPower(), ruleInstalled: true), now: Date())
            }
            if action == .enable, await Self.sleepDisabledAlready(), !FileManager.default.fileExists(atPath: marker.path) {
                // Someone else switched sleep off: switching it back on later would undo their choice.
                _ = machine.handle(.failed, now: Date())
                onNotice?(.alreadyOff)
            } else {
                await perform(action)
            }
            schedule()
            setBusy(false)
        }
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

    /// The app quits: sleep comes back before it is gone.
    func quit() {
        let action = machine.handle(.quit, now: Date())
        guard action != .none || FileManager.default.fileExists(atPath: marker.path) else { return }
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
            if await Task.detached(priority: .userInitiated, operation: { Self.runPmset(true) }).value {
                try? FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Date().ISO8601Format().write(to: marker, atomically: true, encoding: .utf8)
            } else {
                _ = machine.handle(.failed, now: Date())
                onNotice?(.failed)
            }
        case .disable(let reason):
            timer?.cancel()
            // The marker stays when pmset fails, so the next launch tries again.
            if await Task.detached(priority: .userInitiated, operation: { Self.runPmset(false) }).value {
                try? FileManager.default.removeItem(at: marker)
            }
            if reason == .unplugged || reason == .timeUp { onNotice?(.ended(reason)) }
        }
        onChange?(machine.state, busy)
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

    nonisolated private static func runPmset(_ disableSleep: Bool) -> Bool {
        SetupActions.processRunner(LidAwakeCommands.sudo, LidAwakeCommands.sudoArguments(disableSleep), [:]).status == 0
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
