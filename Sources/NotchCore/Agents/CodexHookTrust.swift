import Foundation

/// Whether Codex runs Starnotch's approvals hook. Codex runs a hook from hooks.json only after
/// the user trusted it (the Codex app: Settings › Hooks; the terminal: /hooks), and a trusted
/// hook can be switched off there. Both land in ~/.codex/config.toml, keyed by the hook's place:
///
///     [hooks.state."<hooks.json path>:permission_request:<group>:<handler>"]
///     trusted_hash = "sha256:…"
///     enabled = false
///
/// Read only. A trusted hash counts as trusted; the hash itself isn't checked (Codex hashes a
/// normalized form of the hook's definition). A changed definition makes Codex ask again while
/// the old hash stays, so install-hook.sh keeps ours unchanged on a second run.
public enum CodexHookTrust {
    public enum Status: Equatable, Sendable {
        case notInstalled
        /// In hooks.json, never trusted in Codex: Codex doesn't run it.
        case needsTrust
        /// Switched off in Codex (the hook, or all hooks in `[features]`).
        case switchedOff
        case active

        /// One line for the setup page and Settings.
        public var title: String {
            switch self {
            case .notInstalled: "Not set up"
            case .needsTrust: "Approve it in Codex › Settings › Hooks"
            case .switchedOff: "Switched off in Codex"
            case .active: "Active"
            }
        }

        /// Installed, but Codex doesn't run it: approvals stay in Codex's own window.
        public var isBlocked: Bool { self == .needsTrust || self == .switchedOff }
    }

    /// Where the user trusts the hook, in the Codex app and in the terminal.
    public static let whereToTrust = "In the Codex app: Settings › Hooks › Asking in the notch › Trust, and switch it on. In the terminal: /hooks."

    /// Our hook's command names the script install-hook.sh copies.
    static let marker = "starnotch-ask-notch"
    /// A Codex approval through the hook this recently proves Codex runs it.
    public static let provenWithin: TimeInterval = 7 * 86_400

    public static func status(codexHome: URL, lastRequest: Date? = nil, now: Date = Date()) -> Status {
        let hooksFile = codexHome.appending(path: "hooks.json")
        let config = try? String(contentsOf: codexHome.appending(path: "config.toml"), encoding: .utf8)
        // Codex keys the state by the path it read; a symlinked folder may show either form.
        let paths = [hooksFile.path, hooksFile.resolvingSymlinksInPath().path]
        return status(hooks: try? Data(contentsOf: hooksFile), config: config, hooksPaths: paths,
                      lastRequest: lastRequest, now: now)
    }

    static func status(hooks: Data?, config: String?, hooksPaths: [String], lastRequest: Date?, now: Date) -> Status {
        guard let hooks, let place = place(in: hooks) else { return .notInstalled }
        // Named apart from state(in:key:): an older compiler reads the call as this constant.
        let found: (trusted: Bool, enabled: Bool?) = hooksPaths.lazy
            .map { Self.state(in: config ?? "", key: key(hooksPath: $0, place)) }
            .first { $0.trusted || $0.enabled != nil } ?? (false, nil)
        if found.enabled == false || hooksSwitchedOff(config ?? "") { return .switchedOff }
        if found.trusted { return .active }
        if let lastRequest, now.timeIntervalSince(lastRequest) < provenWithin { return .active }
        return .needsTrust
    }

    /// Our hook's group and handler index among the PermissionRequest hooks (Codex counts from 0).
    static func place(in hooks: Data) -> (group: Int, handler: Int)? {
        guard let root = try? JSONSerialization.jsonObject(with: hooks) as? [String: Any],
              let groups = (root["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]] else { return nil }
        for (group, entry) in groups.enumerated() {
            let handlers = entry["hooks"] as? [[String: Any]] ?? []
            if let handler = handlers.firstIndex(where: { ($0["command"] as? String)?.contains(marker) == true }) {
                return (group, handler)
            }
        }
        return nil
    }

    static func key(hooksPath: String, _ place: (group: Int, handler: Int)) -> String {
        "\(hooksPath):permission_request:\(place.group):\(place.handler)"
    }

    /// The `[hooks.state."<key>"]` table, line by line: a trusted hash, and `enabled` when set.
    static func state(in config: String, key: String) -> (trusted: Bool, enabled: Bool?) {
        var inTable = false
        var trusted = false
        var enabled: Bool?
        for raw in config.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                let name = line.replacingOccurrences(of: " ", with: "")
                inTable = name == "[hooks.state.\"\(key)\"]" || name == "[hooks.state.'\(key)']"
                continue
            }
            guard inTable, let (name, value) = assignment(line) else { continue }
            if name == "trusted_hash" { trusted = value.count > 2 }
            if name == "enabled" { enabled = value == "true" ? true : value == "false" ? false : nil }
        }
        return (trusted, enabled)
    }

    /// `hooks = false` (or the older `codex_hooks`) under `[features]` turns every hook off.
    static func hooksSwitchedOff(_ config: String) -> Bool {
        var table = ""
        for raw in config.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { table = line.replacingOccurrences(of: " ", with: ""); continue }
            guard table == "[features]", let (name, value) = assignment(line) else { continue }
            if (name == "hooks" || name == "codex_hooks") && value == "false" { return true }
        }
        return false
    }

    /// `name = value` without a trailing comment; nil for comments and other lines.
    private static func assignment(_ line: String) -> (String, String)? {
        guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { return nil }
        let name = line[..<equals].trimmingCharacters(in: .whitespaces)
        let value = NotchConfig.stripComment(String(line[line.index(after: equals)...])).trimmingCharacters(in: .whitespaces)
        return (name, value)
    }

    /// One line a day at most, while the hook is installed but Codex doesn't run it.
    public static func nudgeDue(_ status: Status, lastShown: String?, now: Date, calendar: Calendar = .current) -> Bool {
        status.isBlocked && lastShown != MorningLine.day(now, calendar: calendar)
    }
}
