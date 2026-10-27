import Foundation
import NotchCore

/// What the meeting agent needs, without a terminal: the agent ships inside the app
/// (`Resources/agent`) and runs from a copy in Application Support, where `uv` keeps its
/// environment without touching the signed bundle. The keys are typed into Settings and kept in
/// `agent.env` (0600) next to it; `uv` is the one thing to install.
enum MeetingAgentSetup {
    /// The keys the agent's programs read.
    static let keyNames = ["ANTHROPIC_API_KEY", "RESON8_API_KEY"]

    static var folder: URL { Brand.supportFolder.appending(path: "agent") }
    static var keysFile: URL { Brand.supportFolder.appending(path: "agent.env") }

    /// The agent inside this app, if the build has one.
    static var bundled: URL? {
        guard let url = Bundle.main.resourceURL?.appending(path: "agent"),
              FileManager.default.fileExists(atPath: url.appending(path: "agent.py").path) else { return nil }
        return url
    }

    nonisolated(unsafe) private static var installed: URL?

    /// The copy in Application Support, refreshed when the bundled agent changed (its files' names,
    /// sizes and dates). The copy's `.venv` and anything else of the user's stays.
    static func ensureInstalled() -> URL? {
        if let installed { return installed }
        guard let bundled else { return nil }
        let manager = FileManager.default
        let stamp = folder.appending(path: ".bundled")
        let print = fingerprint(bundled)
        if (try? String(contentsOf: stamp, encoding: .utf8)) != print {
            do {
                try manager.createDirectory(at: folder, withIntermediateDirectories: true)
                for name in try manager.contentsOfDirectory(atPath: bundled.path) where !name.hasPrefix(".") {
                    let target = folder.appending(path: name)
                    if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
                    try manager.copyItem(at: bundled.appending(path: name), to: target)
                }
                try print.write(to: stamp, atomically: true, encoding: .utf8)
                Log.app.info("Meeting agent installed in \(folder.path, privacy: .public)")
            } catch {
                Log.app.error("Meeting agent install failed: \(error.localizedDescription, privacy: .public)")
                return manager.fileExists(atPath: folder.appending(path: "agent.py").path) ? folder : nil
            }
        }
        installed = folder
        return folder
    }

    private static func fingerprint(_ folder: URL) -> String {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys)?
            .compactMap { $0 as? URL } ?? []
        return files.map { url -> String in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let date = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            return "\(url.path.dropFirst(folder.path.count)):\(values?.fileSize ?? 0):\(Int(date))"
        }
        .sorted()
        .joined(separator: "\n")
    }

    // MARK: Keys

    /// The keys from `agent.env`, by name.
    static func keys() -> [String: String] {
        guard let text = try? String(contentsOf: keysFile, encoding: .utf8) else { return [:] }
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, keyNames.contains(parts[0]), !parts[1].isEmpty else { continue }
            values[parts[0]] = parts[1]
        }
        return values
    }

    /// Saves one key (empty removes it). The file is readable by the user only.
    static func setKey(_ name: String, _ value: String) {
        var values = keys()
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        values[name] = clean.isEmpty ? nil : clean
        let text = values.keys.sorted().map { "\($0)=\(values[$0] ?? "")" }.joined(separator: "\n") + "\n"
        try? FileManager.default.createDirectory(at: Brand.supportFolder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: keysFile.path, contents: Data(text.utf8),
                                       attributes: [.posixPermissions: 0o600])
    }

    /// The environment for the agent's processes: the app's own, the brain, and the keys under a prefix,
    /// which the shell prelude exports after `~/.zshrc` (so a key typed in Settings wins). The keys
    /// never appear in a command line.
    static func environment() -> [String] {
        var list = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        for (name, value) in keys() { list.append("STARNOTCH_KEY_\(name)=\(value)") }
        // How Tara thinks (onboarding or Settings › Meeting agent): claude-code, api, rules or auto.
        list.removeAll { $0.hasPrefix("STARNOTCH_BRAIN=") }
        list.append("STARNOTCH_BRAIN=\(SettingsStore().load().brain.rawValue)")
        return list
    }

    /// Runs before every agent command in the login shell: the keys from Settings, and the usual
    /// places of `uv` on the PATH in case `~/.zshrc` doesn't add them.
    static let prelude = #"for k in ANTHROPIC_API_KEY RESON8_API_KEY; do v="STARNOTCH_KEY_$k"; [[ -n "${(P)v}" ]] && export "$k=${(P)v}"; done; unset STARNOTCH_KEY_ANTHROPIC_API_KEY STARNOTCH_KEY_RESON8_API_KEY; export PATH="$PATH:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.cargo/bin"; "#

    // MARK: uv

    /// Where `uv` usually lives; nil when none of them has it.
    static var uvPath: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/uv", "/opt/homebrew/bin/uv", "/usr/local/bin/uv", "\(home)/.cargo/bin/uv"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The official installer, for the clipboard.
    static let uvInstallCommand = "curl -LsSf https://astral.sh/uv/install.sh | sh"

    /// What is missing, in the order to fix it; empty when the agent can run.
    static func missing(agentFound: Bool) -> [String] {
        var list: [String] = []
        if !agentFound { list.append("the agent folder") }
        if uvPath == nil { list.append("uv") }
        return list
    }
}
