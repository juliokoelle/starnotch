import Foundation

/// GitHub Copilot CLI: its session folders (`~/.copilot/session-state/<id>/` with `events.jsonl`
/// and `workspace.yaml`) and, once set up, its hooks (`~/.copilot/hooks/starnotch.json`), whose
/// `permissionRequest` can allow or deny from the island. Read-only; each events file is read
/// from its tail. No plan limits: Copilot keeps them on its server.
public actor CopilotProvider: AgentProvider, HookSessionSource {
    public static let id = "copilot"
    public static let displayName = "Copilot CLI"

    public static var defaultRoot: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: ".copilot") }

    /// Installed means a session folder or the command; a leftover config file alone isn't enough.
    public static func detect() -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: defaultRoot.appending(path: "session-state").path)
            || ["/opt/homebrew/bin/copilot", "/usr/local/bin/copilot",
                fm.homeDirectoryForCurrentUser.appending(path: ".local/bin/copilot").path].contains { fm.isExecutableFile(atPath: $0) }
    }

    /// Sessions changed within this window are read; shown while working, recent or running.
    static let candidateWindow: TimeInterval = 6 * 3600
    static let recentWindow: TimeInterval = 30 * 60
    static let maxSessions = 6

    public nonisolated let root: URL
    private var tool: HookedTool
    private var cache: [String: (mtime: Date, state: CopilotSessionFile)] = [:]

    public init(root: URL = CopilotProvider.defaultRoot, useProcesses: Bool = true) {
        self.root = root
        tool = HookedTool(names: ["copilot"], scripts: ["@github/copilot"], useProcesses: useProcesses)
    }

    public nonisolated var watchPaths: [URL] { [root.appending(path: "session-state")] }

    public func ingest(_ update: HookUpdate) { tool.hooks.apply(update) }

    public func scan(now: Date) async -> ProviderScan {
        ProviderScan(sessions: tool.sessions(provider: Self.id, now: now, files: fileSessions(now: now)))
    }

    func fileSessions(now: Date) -> [AgentSession] {
        let folder = root.appending(path: "session-state")
        let dirs = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var found: [(String, CopilotSessionFile, Date)] = []
        for dir in dirs {
            let events = dir.appending(path: "events.jsonl")
            guard let mtime = ClaudeCodeProvider.mtime(events), now.timeIntervalSince(mtime) < Self.candidateWindow else { continue }
            let id = dir.lastPathComponent
            if let cached = cache[id], cached.mtime == mtime {
                found.append((id, cached.state, mtime))
                continue
            }
            var state = CopilotSessionFile()
            state.feed(workspace: (try? String(contentsOf: dir.appending(path: "workspace.yaml"), encoding: .utf8)) ?? "")
            state.feed(lines: Substring(ClaudeCodeProvider.tail(of: events, bytes: 128 * 1024)))
            cache[id] = (mtime, state)
            found.append((id, state, mtime))
        }
        return found.sorted { $0.2 > $1.2 }.compactMap { id, state, mtime -> AgentSession? in
            let busy = state.isBusy && now.timeIntervalSince(mtime) < HookSessions.staleBusy
            guard busy || now.timeIntervalSince(mtime) < Self.recentWindow, !state.ended else { return nil }
            let cwd = state.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
            return AgentSession(id: "\(Self.id):\(id)", project: ProjectPaths.projectName(ofCwd: cwd),
                                title: state.title ?? state.firstPrompt, cwd: cwd, isBusy: busy,
                                since: state.since ?? mtime, steps: state.steps, branch: state.branch,
                                lastMessage: state.lastMessage, model: state.model, provider: Self.id)
        }.prefix(Self.maxSessions).map { $0 }
    }
}

/// What one Copilot CLI session folder says: `workspace.yaml` (folder, name, branch) and the
/// tail of `events.jsonl` (`session.start`, `user.message`, `assistant.turn_start/end`,
/// `tool.execution_start/complete` …). Unknown event types are skipped.
public struct CopilotSessionFile: Equatable, Sendable {
    public var cwd: String?
    public var title: String?
    public var branch: String?
    public var firstPrompt: String?
    public var lastMessage: String?
    public var model: String?
    public var isBusy = false
    public var ended = false
    public var since: Date?
    public var steps: [SessionStep] = []

    public init() {}

    /// The top-level `key: value` lines of workspace.yaml.
    public mutating func feed(workspace yaml: String) {
        for line in yaml.split(whereSeparator: \.isNewline) where !line.hasPrefix(" ") && !line.hasPrefix("#") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            guard !value.isEmpty else { continue }
            switch key {
            case "cwd": cwd = value
            case "git_root" where cwd == nil: cwd = value
            case "name", "title": title = HookUpdate.short(value)
            case "summary" where title == nil: title = HookUpdate.short(value)
            case "branch", "git_branch": branch = value
            default: break
            }
        }
    }

    public mutating func feed(lines: Substring) {
        for line in lines.split(whereSeparator: \.isNewline) {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            let data = object["data"] as? [String: Any] ?? [:]
            let at = (object["timestamp"] as? String).flatMap(SessionLog.parseDate)
            func text(_ key: String) -> String? { (data[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
            func phase(_ busy: Bool) {
                if busy != isBusy { isBusy = busy; since = at ?? since }
            }
            switch type {
            case "session.start":
                if let context = data["context"] as? [String: Any] {
                    cwd = cwd ?? (context["cwd"] as? String)
                    branch = branch ?? (context["branch"] as? String)
                }
                since = since ?? at
            case "session.model_change", "session.info":
                model = text("newModel") ?? text("model") ?? model
            case "user.message":
                if firstPrompt == nil, let content = text("content") { firstPrompt = HookUpdate.short(content) }
                phase(true)
            case "assistant.turn_start":
                phase(true)
            case "assistant.message":
                if let content = text("content") { lastMessage = HookUpdate.short(content) }
            case "tool.execution_start":
                let tool = text("toolName") ?? text("name") ?? "tool"
                var step = HookUpdate.step(tool: tool, input: data["arguments"] as? [String: Any])
                step.date = at
                steps.append(step)
                if steps.count > 8 { steps.removeFirst(steps.count - 8) }
                phase(true)
            case "assistant.turn_end", "abort", "session.idle":
                phase(false)
            case "session.end", "session.shutdown":
                ended = true
                phase(false)
            default:
                break
            }
        }
    }
}
