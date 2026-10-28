import Foundation

// Tara's memory in the user's AI apps: the read-only MCP server `agent/memory_mcp.py`, registered
// in Claude Desktop, Claude Code, Cursor and ChatGPT's Mac app. Each registration keeps a backup
// and comes out exactly; everything takes the home folder from `SetupPaths`, so tests use a
// temporary one.

extension SetupPaths {
    public var claudeDesktopConfig: URL { home.appending(path: "Library/Application Support/Claude/claude_desktop_config.json") }
    public var cursorMCPConfig: URL { cursorHome.appending(path: "mcp.json") }
    /// Codex's config; ChatGPT's Mac app runs its local tools (MCP servers) from it too.
    public var codexConfig: URL { codexHome.appending(path: "config.toml") }
}

extension SetupActions {
    public static let memoryMCPName = "starnotch-memory"
    static let memoryScript = "memory_mcp.py"

    /// `uv run --directory <agent> python memory_mcp.py`, absolute paths only.
    public static func memoryCommand(_ paths: SetupPaths) throws -> [String] {
        guard let uv = paths.uvBinary else { throw SetupError.missing("uv (Settings › Meeting agent › Install uv)") }
        guard FileManager.default.fileExists(atPath: paths.agentFolder.appending(path: memoryScript).path) else {
            throw SetupError.missing("The agent's memory server")
        }
        return [uv, "run", "--directory", paths.agentFolder.path, "python", memoryScript]
    }

    public static func installMemory(_ item: SetupItem, _ paths: SetupPaths, run: SetupRunner = processRunner,
                                     now: Date = Date()) throws -> SetupLedger.Entry {
        switch item {
        case .memoryClaudeDesktop:
            guard FileManager.default.fileExists(atPath: paths.claudeDesktopConfig.deletingLastPathComponent().path) else {
                throw SetupError.missing("Claude Desktop (~/Library/Application Support/Claude)")
            }
            return try addJSONServer(item, file: paths.claudeDesktopConfig, label: "claude_desktop_config.json", backupName: "claude-desktop-config.json",
                                     paths: paths, now: now, note: "Quit and reopen Claude Desktop.")
        case .memoryCursor:
            guard FileManager.default.fileExists(atPath: paths.cursorHome.path) else { throw SetupError.missing("Cursor (~/.cursor)") }
            return try addJSONServer(item, file: paths.cursorMCPConfig, label: "~/.cursor/mcp.json", backupName: "cursor-mcp.json",
                                     paths: paths, now: now, note: "Cursor picks it up in new chats.")
        case .memoryClaudeCode:
            guard let claude = paths.claudeBinary else { throw SetupError.missing("The claude command") }
            let command = try memoryCommand(paths)
            let env = ["HOME": paths.home.path]
            _ = run(claude, ["mcp", "remove", "--scope", "user", memoryMCPName], env)
            let result = run(claude, ["mcp", "add", "--scope", "user", memoryMCPName, "--"] + command, env)
            guard result.status == 0 else {
                throw SetupError.failed("claude mcp add: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            return SetupLedger.Entry(item: item, at: now, note: "Restart running sessions.")
        case .memoryChatGPT:
            return try addCodexBlock(paths, now: now)
        default:
            throw SetupError.failed("Not a memory item")
        }
    }

    public static func removeMemory(_ item: SetupItem, _ paths: SetupPaths, entry: SetupLedger.Entry?,
                                    run: SetupRunner = processRunner) throws {
        switch item {
        case .memoryClaudeDesktop: try removeJSONServer(file: paths.claudeDesktopConfig, label: "claude_desktop_config.json", entry: entry)
        case .memoryCursor: try removeJSONServer(file: paths.cursorMCPConfig, label: "~/.cursor/mcp.json", entry: entry)
        case .memoryClaudeCode:
            guard let claude = paths.claudeBinary else { throw SetupError.missing("The claude command") }
            _ = run(claude, ["mcp", "remove", "--scope", "user", memoryMCPName], ["HOME": paths.home.path])
        case .memoryChatGPT: try removeCodexBlock(paths)
        default: break
        }
    }

    // MARK: JSON configs (Claude Desktop, Cursor)

    /// Ours: an entry that runs memory_mcp.py.
    static func isMemoryServer(_ value: Any?) -> Bool {
        ((value as? [String: Any])?["args"] as? [String])?.contains(memoryScript) == true
    }

    /// Adds `mcpServers.starnotch-memory`. A server of that name that isn't ours is kept in the
    /// ledger and comes back on Remove; a file that isn't JSON stops the change.
    static func addJSONServer(_ item: SetupItem, file: URL, label: String, backupName: String, paths: SetupPaths,
                              now: Date, note: String) throws -> SetupLedger.Entry {
        let command = try memoryCommand(paths)
        var (root, existed) = try readJSON(file, name: label)
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        if root["mcpServers"] != nil, root["mcpServers"] as? [String: Any] == nil {
            throw SetupError.failed("\(label) has an mcpServers that isn't an object; nothing was changed.")
        }
        let ours: [String: Any] = ["command": command[0], "args": Array(command.dropFirst())]
        if let current = servers[memoryMCPName] as? [String: Any], NSDictionary(dictionary: current).isEqual(to: ours) {
            return SetupLedger.Entry(item: item, at: now, note: "Was already set up.")
        }
        let backup = try backup(file, name: backupName, paths: paths, now: now)
        var previous: [String: Any] = ["file": existed ? "existed" : "created"]
        if let old = servers[memoryMCPName], !isMemoryServer(old) { previous["entry"] = old }
        servers[memoryMCPName] = ours
        root["mcpServers"] = servers
        try writeJSON(root, to: file)
        let saved = String(decoding: try JSONSerialization.data(withJSONObject: previous, options: [.sortedKeys]), as: UTF8.self)
        return SetupLedger.Entry(item: item, at: now, backup: backup, previous: saved, note: note)
    }

    /// Takes our entry out (a server of that name from before comes back); a file we created and
    /// that holds nothing else goes. An entry the user changed since is left alone.
    static func removeJSONServer(file: URL, label: String, entry: SetupLedger.Entry?) throws {
        guard let (object, existed) = try? readJSON(file, name: label), existed else { return }
        var root = object
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        guard let current = servers[memoryMCPName] else { return }
        guard isMemoryServer(current) else { throw SetupError.failed("The starnotch-memory server in \(label) was changed since; left as it is.") }
        let previous = entry?.previous.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
        servers[memoryMCPName] = previous["entry"]
        if servers.isEmpty, previous["file"] as? String == "created", Set(root.keys) == ["mcpServers"] {
            try FileManager.default.removeItem(at: file)
            return
        }
        root["mcpServers"] = servers
        try writeJSON(root, to: file)
    }

    // MARK: Codex's config.toml (ChatGPT)

    static let codexBegin = "# >>> Starnotch: Tara's memory (remove it in Starnotch Settings › What's set up)"
    static let codexEnd = "# <<< Starnotch <<<"

    /// A TOML basic string.
    static func tomlString(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    static func codexBlock(_ command: [String]) -> String {
        let args = command.dropFirst().map(tomlString).joined(separator: ", ")
        return "\(codexBegin)\n[mcp_servers.\(memoryMCPName)]\ncommand = \(tomlString(command[0]))\nargs = [\(args)]\n\(codexEnd)\n"
    }

    /// Whether the TOML already defines the server, or `mcp_servers` in a way a new table can't
    /// join (an inline table): adding ours then would break the whole file.
    static func codexConflict(_ text: String) -> String? {
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "")
            if line.hasPrefix("[mcp_servers.\(memoryMCPName)]") || line.hasPrefix("[mcp_servers.\"\(memoryMCPName)\"]")
                || line.hasPrefix("[mcp_servers.'\(memoryMCPName)']") {
                return "Codex's config already has a starnotch-memory server; nothing was changed."
            }
            if line.hasPrefix("mcp_servers=") || line.hasPrefix("mcp_servers.\(memoryMCPName)") {
                return "Codex's config sets mcp_servers in a way Starnotch can't add to; nothing was changed."
            }
        }
        return nil
    }

    static func addCodexBlock(_ paths: SetupPaths, now: Date) throws -> SetupLedger.Entry {
        guard FileManager.default.fileExists(atPath: paths.codexHome.path) else { throw SetupError.missing("~/.codex") }
        let command = try memoryCommand(paths)
        let existing: String
        if FileManager.default.fileExists(atPath: paths.codexConfig.path) {
            guard let text = try? String(contentsOf: paths.codexConfig, encoding: .utf8) else {
                throw SetupError.failed("~/.codex/config.toml isn't readable text; nothing was changed.")
            }
            existing = text
        } else {
            existing = ""
        }
        if existing.contains(codexBegin) { return SetupLedger.Entry(item: .memoryChatGPT, at: now, note: "Was already set up.") }
        if let conflict = codexConflict(existing) { throw SetupError.failed(conflict) }
        let backup = try backup(paths.codexConfig, name: "codex-config.toml", paths: paths, now: now)
        // One blank line of ours before the block (Remove takes it out again).
        let separator = existing.isEmpty ? "" : existing.hasSuffix("\n") ? "\n" : "\n\n"
        try (existing + separator + codexBlock(command)).write(to: paths.codexConfig, atomically: true, encoding: .utf8)
        return SetupLedger.Entry(item: .memoryChatGPT, at: now, backup: backup, previous: existing.isEmpty ? "created" : nil,
                                 note: "Quit and reopen ChatGPT. Codex reads it too.")
    }

    /// Takes out exactly our block (and the blank line we put before it).
    static func removeCodexBlock(_ paths: SetupPaths) throws {
        guard var text = try? String(contentsOf: paths.codexConfig, encoding: .utf8),
              let begin = text.range(of: codexBegin),
              let end = text.range(of: codexEnd + "\n", range: begin.upperBound..<text.endIndex)
                ?? text.range(of: codexEnd, range: begin.upperBound..<text.endIndex) else { return }
        var start = begin.lowerBound
        // The blank line added before the block, when the block isn't the first thing.
        if start > text.startIndex, text[..<start].hasSuffix("\n\n") || text[..<start] == "\n" { start = text.index(before: start) }
        text.removeSubrange(start..<end.upperBound)
        if text.isEmpty {
            try FileManager.default.removeItem(at: paths.codexConfig)
        } else {
            try text.write(to: paths.codexConfig, atomically: true, encoding: .utf8)
        }
    }
}
