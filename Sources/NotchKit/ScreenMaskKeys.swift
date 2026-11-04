import Foundation
import NotchCore

/// Teaches the screen mask the keys Starnotch already holds on this Mac (`KnownSecrets`): the
/// meeting agent's keys in agent.env, the Keychain items Starnotch writes, and `export NAME=value`
/// lines in ~/.zshrc and ~/.zprofile whose name ends in _KEY, _TOKEN, _SECRET or _PASSWORD (read as
/// text, the shell is never run). Only while screen context reads. The values stay inside
/// `refresh`; the mask keeps salted hashes.
enum ScreenMaskKeys {
    private static let queue = DispatchQueue(label: Brand.identifier + ".screen-mask-keys", qos: .utility)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var active = false

    /// Screen context started reading: the keys are learnt.
    static func start() {
        lock.withLock { active = true }
        refresh()
    }

    /// It stopped: the mask forgets them.
    static func stop() {
        lock.withLock { active = false }
        queue.async { KnownSecrets.current = KnownSecrets() }
    }

    /// A key was saved or removed: learnt again, if screen context reads.
    static func changed() {
        guard lock.withLock({ active }) else { return }
        refresh()
    }

    private static func refresh() {
        queue.async {
            let known = KnownSecrets(collect())
            guard lock.withLock({ active }) else { return }
            KnownSecrets.current = known
        }
    }

    private static func collect() -> [String] {
        var values = Array(MeetingAgentSetup.keys().values)
        for item in Keychain.Item.allCases {
            if let stored = Keychain.string(item) { values += KnownSecrets.values(stored: stored) }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        for name in [".zshrc", ".zprofile"] {
            if let text = try? String(contentsOf: home.appending(path: name), encoding: .utf8) { values += KnownSecrets.shellExports(text) }
        }
        return values
    }
}
