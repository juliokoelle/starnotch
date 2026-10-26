import Foundation

// One-click setup: every change the app makes outside its own folder, made only after the user's
// click on the consent page, each with a backup and an exact undo. Everything here takes the home
// folder as a parameter, so tests run against a temporary one.

/// What the consent page can set up.
public enum SetupItem: String, CaseIterable, Codable, Sendable {
    case claudePlugin, codexHook, statusLine, mcpServer, shellHook, launchAtLogin, calendar, musicAutomation

    public var title: String {
        switch self {
        case .claudePlugin: "Claude Code approvals"
        case .codexHook: "Codex approvals"
        case .statusLine: "Claude plan limits and context"
        case .mcpServer: "Agents can reach you"
        case .shellHook: "Long terminal commands"
        case .launchAtLogin: "Open at login"
        case .calendar: "Calendar access"
        case .musicAutomation: "Music and Spotify control"
        }
    }

    /// Exactly what changes, in one or two lines.
    public func detail(_ paths: SetupPaths) -> String {
        switch self {
        case .claudePlugin:
            "Runs claude plugin marketplace add \(SetupPaths.marketplaceRepo) (or the copy inside the app) and claude plugin install \(SetupPaths.pluginID)."
        case .codexHook:
            "Adds one PermissionRequest hook to ~/.codex/hooks.json, with a backup. Codex asks you to trust it once in /hooks."
        case .statusLine:
            "Sets Claude Code's status line in ~/.claude/settings.json to a bridge that saves the limits, then runs your current status line unchanged. Backup first."
        case .mcpServer:
            "Adds the starnotch MCP server to Claude Code (claude mcp add) and Codex (codex mcp add): any agent can show a line or ask yes or no in the notch."
        case .shellHook:
            "Adds two lines to ~/.zshrc that load a small snippet: commands running longer than 30 s show in the notch. Backup first."
        case .launchAtLogin: "Starts \(Brand.displayName) when you log in (System Settings › General › Login Items)."
        case .calendar: "macOS asks once: your next meeting, its countdown and Join."
        case .musicAutomation: "macOS asks once per player: play, pause and skip from the notch."
        }
    }

    /// Undone by the app (the permissions are undone in System Settings).
    public var isRemovable: Bool { ![.calendar, .musicAutomation].contains(self) }
}

/// Where things live; all of it below `home` (tests pass a temporary one).
public struct SetupPaths: Sendable {
    public static let marketplaceRepo = "juliokoelle/starnotch"
    public static let marketplaceName = "starnotch"
    public static let pluginID = "starnotch-approvals@starnotch"

    public var home: URL
    /// The app's support folder (`~/Library/Application Support/<brand>`).
    public var support: URL
    /// The integrations folder inside the app (marketplace, plugin, Codex installer).
    public var integrations: URL?
    /// The status line bridge script inside the app.
    public var bridgeScript: URL?

    public init(home: URL, support: URL, integrations: URL?, bridgeScript: URL?) {
        self.home = home
        self.support = support
        self.integrations = integrations
        self.bridgeScript = bridgeScript
    }

    public var claudeSettings: URL { home.appending(path: ".claude/settings.json") }
    public var codexHome: URL { home.appending(path: ".codex") }
    public var zshrc: URL { home.appending(path: ".zshrc") }
    public var backups: URL { support.appending(path: "backups") }
    public var ledgerFile: URL { support.appending(path: "setup.json") }
    public var installedBridge: URL { support.appending(path: "bin/statusline-bridge.sh") }
    public var shellSnippet: URL { support.appending(path: "shell/starnotch.zsh") }
    public var shellActivity: URL { support.appending(path: "shell") }

    /// Where `claude` usually lives; the first executable wins.
    public var claudeCandidates: [String] {
        [home.appending(path: ".local/bin/claude").path, home.appending(path: ".claude/local/claude").path,
         "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    }

    public var claudeBinary: String? { claudeCandidates.first { FileManager.default.isExecutableFile(atPath: $0) } }

    public var codexBinary: String? {
        [home.appending(path: ".local/bin/codex").path, "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// `uv`, which runs the agent's Python programs (the MCP server among them).
    public var uvBinary: String? {
        [home.appending(path: ".local/bin/uv").path, "/opt/homebrew/bin/uv", "/usr/local/bin/uv", home.appending(path: ".cargo/bin/uv").path]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The agent's copy in the support folder (the app installs it from its bundle).
    public var agentFolder: URL { support.appending(path: "agent") }
}

/// What was set up, with what it needs to be undone exactly.
public struct SetupLedger: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var item: SetupItem
        public var at: Date
        /// The backup taken before the change.
        public var backup: String?
        /// The value the change replaced (the previous status line, as JSON).
        public var previous: String?
        /// One line for the "What's set up" page.
        public var note: String?

        public init(item: SetupItem, at: Date, backup: String? = nil, previous: String? = nil, note: String? = nil) {
            self.item = item
            self.at = at
            self.backup = backup
            self.previous = previous
            self.note = note
        }
    }

    public var entries: [Entry] = []

    public init(entries: [Entry] = []) { self.entries = entries }

    public func entry(_ item: SetupItem) -> Entry? { entries.last { $0.item == item } }

    public mutating func record(_ entry: Entry) {
        entries.removeAll { $0.item == entry.item }
        entries.append(entry)
    }

    public mutating func forget(_ item: SetupItem) { entries.removeAll { $0.item == item } }

    public static func load(_ url: URL) -> SetupLedger {
        guard let data = try? Data(contentsOf: url) else { return SetupLedger() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(SetupLedger.self, from: data)) ?? SetupLedger()
    }

    public func save(_ url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

public enum SetupError: Error, Equatable, CustomStringConvertible {
    case missing(String)
    case failed(String)

    public var description: String {
        switch self {
        case .missing(let what): "\(what) not found"
        case .failed(let why): why
        }
    }
}

/// Runs a command; tests replace it.
public typealias SetupRunner = @Sendable (_ executable: String, _ arguments: [String], _ environment: [String: String]) -> (status: Int32, output: String)

public enum SetupActions {
    /// A plain `Process` with the given environment on top of the app's.
    public static let processRunner: SetupRunner = { executable, arguments, environment in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// Copies `file` into the backups folder; nil when there is nothing to back up.
    static func backup(_ file: URL, name: String, paths: SetupPaths, now: Date) throws -> String? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        try FileManager.default.createDirectory(at: paths.backups, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var target = paths.backups.appending(path: "\(name)-\(stamp(now))")
        var suffix = 1
        while FileManager.default.fileExists(atPath: target.path) {
            suffix += 1
            target = paths.backups.appending(path: "\(name)-\(stamp(now))-\(suffix)")
        }
        try FileManager.default.copyItem(at: file, to: target)
        return target.path
    }

    // MARK: Claude Code plugin

    /// Adds the marketplace (the GitHub repository, else the copy inside the app) and installs the plugin.
    public static func installClaudePlugin(_ paths: SetupPaths, run: SetupRunner = processRunner, now: Date = Date()) throws -> SetupLedger.Entry {
        guard let claude = paths.claudeBinary else { throw SetupError.missing("The claude command") }
        let env = ["HOME": paths.home.path]
        var source = SetupPaths.marketplaceRepo
        var added = run(claude, ["plugin", "marketplace", "add", source], env)
        if added.status != 0, !added.output.localizedCaseInsensitiveContains("already") {
            guard let local = paths.integrations?.appending(path: "claude-code"),
                  FileManager.default.fileExists(atPath: local.appending(path: ".claude-plugin/marketplace.json").path) else {
                throw SetupError.failed("Couldn't add the marketplace: \(added.output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            source = local.path
            added = run(claude, ["plugin", "marketplace", "add", source], env)
            guard added.status == 0 || added.output.localizedCaseInsensitiveContains("already") else {
                throw SetupError.failed("Couldn't add the marketplace: \(added.output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        let installed = run(claude, ["plugin", "install", SetupPaths.pluginID], env)
        guard installed.status == 0 else {
            throw SetupError.failed("Couldn't install the plugin: \(installed.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return SetupLedger.Entry(item: .claudePlugin, at: now, previous: source, note: "Marketplace: \(source). Restart running sessions.")
    }

    // MARK: MCP server

    public static let mcpName = "starnotch"

    /// The command an MCP client runs: uv with the agent folder, absolute paths only (clients
    /// start servers without the user's shell PATH).
    public static func mcpCommand(_ paths: SetupPaths) throws -> [String] {
        guard let uv = paths.uvBinary else { throw SetupError.missing("uv (Settings › Meeting agent › Install uv)") }
        guard FileManager.default.fileExists(atPath: paths.agentFolder.appending(path: "mcp_server.py").path) else {
            throw SetupError.missing("The agent's MCP server")
        }
        return [uv, "run", "--directory", paths.agentFolder.path, "python", "mcp_server.py"]
    }

    /// `claude mcp add --scope user starnotch -- …`, and the same for Codex when it is installed.
    public static func installMCPServer(_ paths: SetupPaths, run: SetupRunner = processRunner, now: Date = Date()) throws -> SetupLedger.Entry {
        let command = try mcpCommand(paths)
        let env = ["HOME": paths.home.path]
        var added: [String] = []
        if let claude = paths.claudeBinary {
            _ = run(claude, ["mcp", "remove", "--scope", "user", mcpName], env)
            let result = run(claude, ["mcp", "add", "--scope", "user", mcpName, "--"] + command, env)
            guard result.status == 0 else {
                throw SetupError.failed("claude mcp add: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            added.append("Claude Code")
        }
        if let codex = paths.codexBinary {
            _ = run(codex, ["mcp", "remove", mcpName], env)
            if run(codex, ["mcp", "add", mcpName, "--"] + command, env).status == 0 { added.append("Codex") }
        }
        guard !added.isEmpty else { throw SetupError.missing("The claude or codex command") }
        return SetupLedger.Entry(item: .mcpServer, at: now, note: "In \(added.joined(separator: " and ")). Restart running sessions.")
    }

    public static func removeMCPServer(_ paths: SetupPaths, run: SetupRunner = processRunner) throws {
        let env = ["HOME": paths.home.path]
        if let claude = paths.claudeBinary { _ = run(claude, ["mcp", "remove", "--scope", "user", mcpName], env) }
        if let codex = paths.codexBinary { _ = run(codex, ["mcp", "remove", mcpName], env) }
    }

    public static func removeClaudePlugin(_ paths: SetupPaths, run: SetupRunner = processRunner) throws {
        guard let claude = paths.claudeBinary else { throw SetupError.missing("The claude command") }
        let env = ["HOME": paths.home.path]
        let removed = run(claude, ["plugin", "uninstall", SetupPaths.pluginID], env)
        _ = run(claude, ["plugin", "marketplace", "remove", SetupPaths.marketplaceName], env)
        guard removed.status == 0 || removed.output.localizedCaseInsensitiveContains("not installed") else {
            throw SetupError.failed("Couldn't remove the plugin: \(removed.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    // MARK: Codex hook

    public static func installCodexHook(_ paths: SetupPaths, run: SetupRunner = processRunner, now: Date = Date()) throws -> SetupLedger.Entry {
        guard let script = paths.integrations?.appending(path: "claude-code/starnotch-approvals/codex/install-hook.sh"),
              FileManager.default.fileExists(atPath: script.path) else { throw SetupError.missing("The Codex hook installer") }
        guard FileManager.default.fileExists(atPath: paths.codexHome.path) else { throw SetupError.missing("Codex (~/.codex)") }
        let result = run("/bin/bash", [script.path], ["HOME": paths.home.path, "CODEX_HOME": paths.codexHome.path])
        guard result.status == 0 else { throw SetupError.failed(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let backup = result.output.split(separator: "\n").first { $0.hasPrefix("Backup: ") }.map { String($0.dropFirst(8)) }
        return SetupLedger.Entry(item: .codexHook, at: now, backup: backup, note: "Trust it once in Codex: /hooks")
    }

    public static func removeCodexHook(_ paths: SetupPaths, run: SetupRunner = processRunner) throws {
        guard let script = paths.integrations?.appending(path: "claude-code/starnotch-approvals/codex/install-hook.sh") else {
            throw SetupError.missing("The Codex hook installer")
        }
        let result = run("/bin/bash", [script.path, "--remove"], ["HOME": paths.home.path, "CODEX_HOME": paths.codexHome.path])
        guard result.status == 0 else { throw SetupError.failed(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    // MARK: Status line bridge

    /// `NOTCH_SUPPORT_DIR='…' bash '…/statusline-bridge.sh' sh -c '<previous command>'`.
    public static func bridgeCommand(bridge: String, support: String, previous: String?) -> String {
        var command = "NOTCH_SUPPORT_DIR=\(shellQuote(support)) bash \(shellQuote(bridge))"
        if let previous, !previous.trimmingCharacters(in: .whitespaces).isEmpty {
            command += " sh -c \(shellQuote(previous))"
        }
        return command
    }

    public static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Puts the bridge in front of the current status line (which keeps running, unchanged).
    public static func installStatusLine(_ paths: SetupPaths, now: Date = Date()) throws -> SetupLedger.Entry {
        guard let source = paths.bridgeScript, FileManager.default.fileExists(atPath: source.path) else {
            throw SetupError.missing("The status line bridge")
        }
        let fm = FileManager.default
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: paths.claudeSettings), !data.isEmpty {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SetupError.failed("~/.claude/settings.json isn't valid JSON; nothing was changed.")
            }
            settings = object
        }
        let previous = settings["statusLine"] as? [String: Any]
        if let command = previous?["command"] as? String, command.contains("statusline-bridge.sh") {
            return SetupLedger.Entry(item: .statusLine, at: now, note: "Was already set up.")
        }
        let backup = try backup(paths.claudeSettings, name: "claude-settings.json", paths: paths, now: now)
        // The bridge in the app's folder, so moving the app doesn't break the status line.
        try fm.createDirectory(at: paths.installedBridge.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: paths.installedBridge)
        try fm.copyItem(at: source, to: paths.installedBridge)
        chmod(paths.installedBridge.path, 0o755)
        var line: [String: Any] = previous ?? [:]
        line["type"] = "command"
        line["command"] = bridgeCommand(bridge: paths.installedBridge.path, support: paths.support.path,
                                        previous: previous?["command"] as? String)
        if line["refreshInterval"] == nil { line["refreshInterval"] = 60 }
        settings["statusLine"] = line
        try fm.createDirectory(at: paths.claudeSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: paths.claudeSettings, options: .atomic)
        let previousJSON = try previous.map { String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self) }
        return SetupLedger.Entry(item: .statusLine, at: now, backup: backup, previous: previousJSON ?? "null",
                                 note: previous == nil ? "No status line before." : "Your status line keeps running after the bridge.")
    }

    /// Restores the status line from before (or removes the key when there was none). A status
    /// line the user changed since is left alone.
    public static func removeStatusLine(_ paths: SetupPaths, entry: SetupLedger.Entry) throws {
        guard let data = try? Data(contentsOf: paths.claudeSettings),
              var settings = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        guard let command = (settings["statusLine"] as? [String: Any])?["command"] as? String,
              command.contains(paths.installedBridge.path) else {
            throw SetupError.failed("The status line was changed since; left as it is.")
        }
        if let previous = entry.previous, previous != "null", let object = try? JSONSerialization.jsonObject(with: Data(previous.utf8)) {
            settings["statusLine"] = object
        } else {
            settings.removeValue(forKey: "statusLine")
        }
        let out = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try out.write(to: paths.claudeSettings, options: .atomic)
        try? FileManager.default.removeItem(at: paths.installedBridge)
    }

    // MARK: Shell hook

    static let shellBegin = "# >>> Starnotch >>> (added by Starnotch; remove it in Settings › What's set up)"
    static let shellEnd = "# <<< Starnotch <<<"

    public static func installShellHook(_ paths: SetupPaths, now: Date = Date()) throws -> SetupLedger.Entry {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.shellActivity, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try ShellActivity.snippet(folder: paths.shellActivity.path).write(to: paths.shellSnippet, atomically: true, encoding: .utf8)
        let existing = (try? String(contentsOf: paths.zshrc, encoding: .utf8)) ?? ""
        if existing.contains(shellBegin) { return SetupLedger.Entry(item: .shellHook, at: now, note: "Was already set up.") }
        let backup = try backup(paths.zshrc, name: "zshrc", paths: paths, now: now)
        let block = "\n\(shellBegin)\n[ -f \(shellQuote(paths.shellSnippet.path)) ] && source \(shellQuote(paths.shellSnippet.path))\n\(shellEnd)\n"
        try (existing + block).write(to: paths.zshrc, atomically: true, encoding: .utf8)
        return SetupLedger.Entry(item: .shellHook, at: now, backup: backup, note: "New terminal windows pick it up.")
    }

    public static func removeShellHook(_ paths: SetupPaths) throws {
        if var text = try? String(contentsOf: paths.zshrc, encoding: .utf8),
           let begin = text.range(of: "\n" + shellBegin) ?? text.range(of: shellBegin),
           let end = text.range(of: shellEnd + "\n", range: begin.upperBound..<text.endIndex)
            ?? text.range(of: shellEnd, range: begin.upperBound..<text.endIndex) {
            text.removeSubrange(begin.lowerBound..<end.upperBound)
            try text.write(to: paths.zshrc, atomically: true, encoding: .utf8)
        }
        try? FileManager.default.removeItem(at: paths.shellSnippet)
    }
}
