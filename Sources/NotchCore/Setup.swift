import Foundation

// One-click setup: every change the app makes outside its own folder, made only after the user's
// click on the consent page, each with a backup and an exact undo. Everything here takes the home
// folder as a parameter, so tests run against a temporary one.

/// What the consent page can set up.
public enum SetupItem: String, CaseIterable, Codable, Sendable {
    case claudePlugin, codexHook, statusLine, mcpServer, shellHook, launchAtLogin, calendar, musicAutomation
    /// Not on the consent page: set up the first time the user switches it on (System tab).
    case lidAwake
    // Strand agents: more agent tools, each off until chosen.
    case cursorHooks, copilotHooks, geminiHooks, opencodePlugin
    /// Answering Cursor's and Copilot CLI's prompts in the notch: their hooks run before every
    /// shell (and MCP) call, so this is a choice of its own, offered once the status is set up.
    case cursorApprovals, copilotApprovals

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
        case .lidAwake: "Keep awake with the lid closed"
        case .cursorHooks: "Cursor status"
        case .copilotHooks: "Copilot CLI status"
        case .geminiHooks: "Gemini CLI status"
        case .opencodePlugin: "opencode status and approvals"
        case .cursorApprovals: "Answer Cursor in the notch"
        case .copilotApprovals: "Answer Copilot CLI in the notch"
        }
    }

    /// Exactly what changes, in one or two lines.
    public func detail(_ paths: SetupPaths) -> String {
        switch self {
        case .claudePlugin:
            "Runs claude plugin marketplace add \(SetupPaths.marketplaceRepo) (or the app's copy of its own marketplace folder, in its support folder) and claude plugin install \(SetupPaths.pluginID)."
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
        case .lidAwake: "Adds \(LidAwakeCommands.ruleFile): lets you run pmset -a disablesleep 1 and 0 without a password, nothing else."
        case .cursorHooks:
            "Adds Starnotch's status hooks to ~/.cursor/hooks.json, with a backup. They only report; Cursor asks and runs as before."
        case .copilotHooks:
            "Adds ~/.copilot/hooks/starnotch.json: sessions show in the notch, and when Copilot asks you it shows as waiting. It never answers."
        case .geminiHooks:
            "Adds Starnotch's hooks to ~/.gemini/settings.json, with a backup. Gemini's hooks can't allow, so a prompt shows as waiting with a jump to its terminal."
        case .opencodePlugin:
            "Adds a small plugin to ~/.config/opencode/plugins: sessions show in the notch and permission prompts can be answered there."
        case .cursorApprovals:
            "Adds two hooks to ~/.cursor/hooks.json, with a backup. Every shell and MCP command waits up to 30 s for your answer in the notch, also those on Cursor's allowlist; unanswered or with the app closed, Cursor asks you itself."
        case .copilotApprovals:
            "Adds ~/.copilot/hooks/starnotch-approvals.json. Shell, edit and MCP requests wait up to 30 s for your answer in the notch, also those Copilot would allow on its own; unanswered, Copilot goes on as usual. Sessions started with --allow-all are left alone."
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
    /// Exists while Starnotch keeps the Mac awake with the lid closed.
    public var lidAwakeMarker: URL { support.appending(path: "lid-awake") }

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

    // Strand agents: the other agent tools' folders and Starnotch's files there.
    public var cursorHome: URL { home.appending(path: ".cursor") }
    public var copilotHome: URL { home.appending(path: ".copilot") }
    public var geminiHome: URL { home.appending(path: ".gemini") }
    public var opencodePlugins: URL { home.appending(path: ".config/opencode/plugins") }
    /// The shared hook script inside the app (integrations/agents).
    public var hookScriptSource: URL? { integrations?.appending(path: "agents/starnotch-hook.sh") }
    public var opencodePluginSource: URL? { integrations?.appending(path: "agents/opencode/starnotch.js") }
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

    /// Adds the marketplace (the GitHub repository, else the app's copy in its support folder) and installs the plugin.
    public static func installClaudePlugin(_ paths: SetupPaths, run: SetupRunner = processRunner, now: Date = Date()) throws -> SetupLedger.Entry {
        guard let claude = paths.claudeBinary else { throw SetupError.missing("The claude command") }
        let env = ["HOME": paths.home.path]
        var source = SetupPaths.marketplaceRepo
        var added = run(claude, ["plugin", "marketplace", "add", source], env)
        if added.status != 0, !added.output.localizedCaseInsensitiveContains("already") {
            guard let local = try? placeClaudePluginCopy(paths) else {
                throw SetupError.failed("Couldn't add the marketplace: \(added.output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            source = local.path
            added = run(claude, ["plugin", "marketplace", "add", source], env)
            guard added.status == 0 || added.output.localizedCaseInsensitiveContains("already") else {
                throw SetupError.failed("Couldn't add the marketplace: \(added.output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        // Already there: it may point at a folder that is gone (a moved or deleted build).
        if added.output.localizedCaseInsensitiveContains("already"),
           let registered = (try? Data(contentsOf: paths.knownMarketplaces)).flatMap(ClaudePluginCheck.marketplace), registered != .absent {
            if !ClaudePluginCheck.isCurrent(registered, stableCopy: paths.claudePluginCopy, exists: { FileManager.default.fileExists(atPath: $0) }) {
                source = try registerClaudePluginCopy(paths, claude: claude, previous: registered, run: run, env: env).path
            } else if case .directory(let path) = registered {
                source = path
            } else {
                source = SetupPaths.marketplaceRepo
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
        try? FileManager.default.removeItem(at: paths.claudePluginCopy)
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

// MARK: - Strand agents: Cursor, Copilot CLI, Gemini CLI, opencode

extension SetupActions {
    /// Every file Starnotch adds for these tools carries this name, so Remove finds exactly its own.
    public static let hookScriptName = "starnotch-hook.sh"

    /// Cursor's events that only report (they never change what Cursor does) …
    static let cursorEvents = ["sessionStart", "sessionEnd", "beforeSubmitPrompt", "afterShellExecution",
                               "afterMCPExecution", "afterFileEdit", "stop"]
    /// … and the two the island answers, a choice of their own (`cursorApprovals`): they run
    /// before every shell and MCP call, not only the ones Cursor would ask about.
    static let cursorApprovalEvents = ["beforeShellExecution", "beforeMCPExecution"]
    static let copilotEvents = ["sessionStart", "sessionEnd", "userPromptSubmitted", "preToolUse", "postToolUse",
                                "agentStop", "errorOccurred", "notification"]
    /// How long a hook that waits for the island may run: past the island's own wait
    /// (`ApprovalRequest.timeout`), so the tool never kills it first.
    static let askTimeout = 45
    static let geminiEvents = ["SessionStart", "SessionEnd", "BeforeAgent", "AfterAgent", "BeforeTool", "AfterTool", "Notification"]

    /// `'<folder>/hooks/starnotch-hook.sh' cursor stop`, plus `--ask` where the island answers.
    static func hookCommand(_ script: URL, provider: String, event: String, ask: Bool) -> String {
        "\(shellQuote(script.path)) \(provider) \(event)" + (ask ? " --ask" : "")
    }

    /// Copies the shared hook script into the tool's own folder (`<tool>/hooks/`).
    static func placeHookScript(_ paths: SetupPaths, in folder: URL) throws -> URL {
        guard let source = paths.hookScriptSource, FileManager.default.fileExists(atPath: source.path) else {
            throw SetupError.missing("The hook script")
        }
        let target = folder.appending(path: "hooks/\(hookScriptName)")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: source, to: target)
        chmod(target.path, 0o755)
        return target
    }

    /// After an app update: the copies of the hook script and the opencode plugin that are set
    /// up get the bundled version, so a fix in them reaches every tool. Only copies that exist
    /// and differ are replaced. Returns what was refreshed.
    @discardableResult
    public static func refreshInstalledCopies(_ paths: SetupPaths, ledger: SetupLedger) -> [URL] {
        var pairs: [(URL?, URL)] = []
        let script = paths.hookScriptSource
        if ledger.entry(.cursorHooks) != nil || ledger.entry(.cursorApprovals) != nil {
            pairs.append((script, paths.cursorHome.appending(path: "hooks/\(hookScriptName)")))
        }
        if ledger.entry(.copilotHooks) != nil || ledger.entry(.copilotApprovals) != nil {
            pairs.append((script, paths.copilotHome.appending(path: "hooks/\(hookScriptName)")))
        }
        if ledger.entry(.geminiHooks) != nil { pairs.append((script, paths.geminiHome.appending(path: "hooks/\(hookScriptName)"))) }
        if ledger.entry(.opencodePlugin) != nil { pairs.append((paths.opencodePluginSource, opencodePluginFile(paths))) }
        var refreshed: [URL] = []
        for (source, target) in pairs {
            guard let source, let fresh = try? Data(contentsOf: source), let installed = try? Data(contentsOf: target),
                  fresh != installed else { continue }
            guard (try? fresh.write(to: target, options: .atomic)) != nil else { continue }
            if target.lastPathComponent == hookScriptName { chmod(target.path, 0o755) }
            refreshed.append(target)
        }
        return refreshed
    }

    /// A JSON settings file, or an empty one; a file that isn't JSON stops the change.
    static func readJSON(_ file: URL, name: String) throws -> (object: [String: Any], existed: Bool) {
        guard let data = try? Data(contentsOf: file), !data.isEmpty else { return ([:], false) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SetupError.failed("\(name) isn't valid JSON; nothing was changed.")
        }
        return (object, true)
    }

    static func writeJSON(_ object: [String: Any], to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data("\n".utf8)).write(to: file, options: .atomic)
    }

    static func isOurs(_ value: Any?) -> Bool { (value as? String)?.contains(hookScriptName) == true }

    // MARK: Cursor

    public static func installCursorHooks(_ paths: SetupPaths, now: Date = Date()) throws -> SetupLedger.Entry {
        let created = try addCursorHooks(paths, events: cursorEvents, ask: false, now: now)
        return SetupLedger.Entry(item: .cursorHooks, at: now, backup: created.backup, previous: created.created ? "created" : nil,
                                 note: "Restart Cursor's agent sessions to pick it up.")
    }

    public static func installCursorApprovals(_ paths: SetupPaths, now: Date = Date()) throws -> SetupLedger.Entry {
        let created = try addCursorHooks(paths, events: cursorApprovalEvents, ask: true, now: now)
        return SetupLedger.Entry(item: .cursorApprovals, at: now, backup: created.backup, previous: created.created ? "created" : nil,
                                 note: "Restart Cursor's agent sessions to pick it up.")
    }

    /// Adds one hook of ours per event beside the user's own (a second run replaces ours).
    static func addCursorHooks(_ paths: SetupPaths, events: [String], ask: Bool, now: Date) throws -> (backup: String?, created: Bool) {
        guard FileManager.default.fileExists(atPath: paths.cursorHome.path) else { throw SetupError.missing("Cursor (~/.cursor)") }
        let file = paths.cursorHome.appending(path: "hooks.json")
        var (root, existed) = try readJSON(file, name: "~/.cursor/hooks.json")
        let backup = try backup(file, name: "cursor-hooks.json", paths: paths, now: now)
        let script = try placeHookScript(paths, in: paths.cursorHome)
        if root["version"] == nil { root["version"] = 1 }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var list = (hooks[event] as? [[String: Any]] ?? []).filter { !isOurs($0["command"]) }
            var hook: [String: Any] = ["command": hookCommand(script, provider: "cursor", event: event, ask: ask)]
            if ask { hook["timeout"] = askTimeout }
            list.append(hook)
            hooks[event] = list
        }
        root["hooks"] = hooks
        try writeJSON(root, to: file)
        return (backup, !existed)
    }

    public static func removeCursorHooks(_ paths: SetupPaths, entry: SetupLedger.Entry?) throws {
        try removeCursorHooks(paths, events: cursorEvents, entry: entry)
    }

    public static func removeCursorApprovals(_ paths: SetupPaths, entry: SetupLedger.Entry?) throws {
        try removeCursorHooks(paths, events: cursorApprovalEvents, entry: entry)
    }

    /// Takes out our hooks of `events`; the script goes with the last of ours, the file when
    /// we created it and nothing else is left.
    static func removeCursorHooks(_ paths: SetupPaths, events: [String], entry: SetupLedger.Entry?) throws {
        let file = paths.cursorHome.appending(path: "hooks.json")
        var oursLeft = false
        if let (object, existed) = try? readJSON(file, name: "~/.cursor/hooks.json"), existed {
            var root = object
            var hooks = root["hooks"] as? [String: Any] ?? [:]
            for (event, value) in hooks {
                guard let list = value as? [[String: Any]] else { continue }
                guard events.contains(event) else {
                    if list.contains(where: { isOurs($0["command"]) }) { oursLeft = true }
                    continue
                }
                let rest = list.filter { !isOurs($0["command"]) }
                hooks[event] = rest.isEmpty ? nil : rest
            }
            if hooks.isEmpty, entry?.previous == "created", Set(root.keys).isSubset(of: ["version", "hooks"]) {
                try? FileManager.default.removeItem(at: file)
            } else {
                root["hooks"] = hooks
                try writeJSON(root, to: file)
            }
        }
        if !oursLeft { try? FileManager.default.removeItem(at: paths.cursorHome.appending(path: "hooks/\(hookScriptName)")) }
    }

    // MARK: Copilot CLI

    /// Starnotch's own hooks file; Copilot reads every file in ~/.copilot/hooks.
    public static func copilotHooksFile(_ paths: SetupPaths) -> URL { paths.copilotHome.appending(path: "hooks/starnotch.json") }

    /// The answering hook, in a file of its own so each choice comes out exactly.
    public static func copilotApprovalsFile(_ paths: SetupPaths) -> URL { paths.copilotHome.appending(path: "hooks/starnotch-approvals.json") }

    public static func installCopilotHooks(_ paths: SetupPaths, now: Date = Date()) throws -> SetupLedger.Entry {
        guard FileManager.default.fileExists(atPath: paths.copilotHome.path) else { throw SetupError.missing("Copilot CLI (~/.copilot)") }
        let file = copilotHooksFile(paths)
        let backup = try backup(file, name: "copilot-starnotch.json", paths: paths, now: now)
        let script = try placeHookScript(paths, in: paths.copilotHome)
        var hooks: [String: Any] = [:]
        for event in copilotEvents {
            var hook: [String: Any] = ["type": "command", "bash": hookCommand(script, provider: "copilot", event: event, ask: false),
                                       "timeoutSec": 5]
            // Only Copilot's own prompt: it waits for you.
            if event == "notification" { hook["matcher"] = "permission_prompt" }
            hooks[event] = [hook]
        }
        try writeJSON(["version": 1, "hooks": hooks], to: file)
        return SetupLedger.Entry(item: .copilotHooks, at: now, backup: backup, note: "New Copilot sessions pick it up.")
    }

    /// `permissionRequest` runs before Copilot's rules and session approvals, so it waits only
    /// `ApprovalRequest.timeout` and then falls through to Copilot's own flow.
    public static func installCopilotApprovals(_ paths: SetupPaths, now: Date = Date()) throws -> SetupLedger.Entry {
        guard FileManager.default.fileExists(atPath: paths.copilotHome.path) else { throw SetupError.missing("Copilot CLI (~/.copilot)") }
        let file = copilotApprovalsFile(paths)
        let backup = try backup(file, name: "copilot-starnotch-approvals.json", paths: paths, now: now)
        let script = try placeHookScript(paths, in: paths.copilotHome)
        let hook: [String: Any] = ["type": "command", "bash": hookCommand(script, provider: "copilot", event: "permissionRequest", ask: true),
                                   "timeoutSec": askTimeout]
        try writeJSON(["version": 1, "hooks": ["permissionRequest": [hook]]], to: file)
        return SetupLedger.Entry(item: .copilotApprovals, at: now, backup: backup, note: "New Copilot sessions pick it up.")
    }

    public static func removeCopilotHooks(_ paths: SetupPaths) throws {
        try removeCopilotFile(copilotHooksFile(paths), paths: paths)
    }

    public static func removeCopilotApprovals(_ paths: SetupPaths) throws {
        try removeCopilotFile(copilotApprovalsFile(paths), paths: paths)
    }

    /// Only a file that is still Starnotch's goes; the script with the last of them.
    static func removeCopilotFile(_ file: URL, paths: SetupPaths) throws {
        if let text = try? String(contentsOf: file, encoding: .utf8), text.contains(hookScriptName) {
            try FileManager.default.removeItem(at: file)
        }
        let others = [copilotHooksFile(paths), copilotApprovalsFile(paths)].filter { $0 != file }
        if !others.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            try? FileManager.default.removeItem(at: paths.copilotHome.appending(path: "hooks/\(hookScriptName)"))
        }
    }

    // MARK: Gemini CLI

    public static func installGeminiHooks(_ paths: SetupPaths, now: Date = Date()) throws -> SetupLedger.Entry {
        guard FileManager.default.fileExists(atPath: paths.geminiHome.path) else { throw SetupError.missing("Gemini CLI (~/.gemini)") }
        let file = paths.geminiHome.appending(path: "settings.json")
        var (root, existed) = try readJSON(file, name: "~/.gemini/settings.json")
        let backup = try backup(file, name: "gemini-settings.json", paths: paths, now: now)
        let script = try placeHookScript(paths, in: paths.geminiHome)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in geminiEvents {
            var groups = (hooks[event] as? [[String: Any]] ?? []).filter { group in
                !(group["hooks"] as? [[String: Any]] ?? []).contains { isOurs($0["command"]) }
            }
            groups.append(["hooks": [["type": "command", "name": "starnotch", "timeout": 5000,
                                      "command": hookCommand(script, provider: "gemini", event: event, ask: false)]]])
            hooks[event] = groups
        }
        root["hooks"] = hooks
        try writeJSON(root, to: file)
        return SetupLedger.Entry(item: .geminiHooks, at: now, backup: backup, previous: existed ? nil : "created",
                                 note: "New Gemini sessions pick it up.")
    }

    public static func removeGeminiHooks(_ paths: SetupPaths, entry: SetupLedger.Entry?) throws {
        let file = paths.geminiHome.appending(path: "settings.json")
        if var (root, existed) = try? readJSON(file, name: "~/.gemini/settings.json"), existed {
            var hooks = root["hooks"] as? [String: Any] ?? [:]
            for (event, value) in hooks {
                guard let groups = value as? [[String: Any]] else { continue }
                let rest = groups.filter { group in !(group["hooks"] as? [[String: Any]] ?? []).contains { isOurs($0["command"]) } }
                hooks[event] = rest.isEmpty ? nil : rest
            }
            root["hooks"] = hooks.isEmpty ? nil : hooks
            if root.isEmpty, entry?.previous == "created" {
                try? FileManager.default.removeItem(at: file)
            } else {
                try writeJSON(root, to: file)
            }
        }
        try? FileManager.default.removeItem(at: paths.geminiHome.appending(path: "hooks/\(hookScriptName)"))
    }

    // MARK: opencode

    public static func opencodePluginFile(_ paths: SetupPaths) -> URL { paths.opencodePlugins.appending(path: "starnotch.js") }

    public static func installOpencodePlugin(_ paths: SetupPaths, now: Date = Date()) throws -> SetupLedger.Entry {
        guard let source = paths.opencodePluginSource, FileManager.default.fileExists(atPath: source.path) else {
            throw SetupError.missing("The opencode plugin")
        }
        let file = opencodePluginFile(paths)
        let backup = try backup(file, name: "opencode-starnotch.js", paths: paths, now: now)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.copyItem(at: source, to: file)
        return SetupLedger.Entry(item: .opencodePlugin, at: now, backup: backup, note: "New opencode sessions pick it up.")
    }

    public static func removeOpencodePlugin(_ paths: SetupPaths) throws {
        let file = opencodePluginFile(paths)
        if let text = try? String(contentsOf: file, encoding: .utf8), text.contains("Starnotch") {
            try FileManager.default.removeItem(at: file)
        }
    }
}
