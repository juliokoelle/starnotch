import Foundation

// One receiver for every tool's hooks: the shared hook script (integrations/agents/starnotch-hook.sh)
// forwards each hook call's JSON to the notch with `starnotch_provider`, `starnotch_event`,
// `starnotch_pid` and `starnotch_tty` added. `HookUpdate.parse` turns it into the same few words
// for every tool; `HookSessions` keeps what they say per session.

/// What one hook call said about a session.
public struct HookUpdate: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The session started (or resumed).
        case started
        /// The user sent a prompt: the agent works. The prompt, shortened, as a fallback title.
        case prompt(String?)
        /// A tool runs (or ran): the agent works, this is its step.
        case tool(SessionStep)
        /// The tool asks the user and can't be answered from outside (Gemini CLI): status only.
        case waiting(String)
        /// The question was answered.
        case answered
        /// The turn ended; the agent's last words when the tool says them.
        case idle(String?)
        /// The session ended.
        case ended
        /// The session got a title (opencode's generated one).
        case title(String)
    }

    public var provider: String
    /// The tool's own session id.
    public var sessionID: String
    public var kind: Kind
    public var at: Date
    public var cwd: String?
    /// The agent's process (the hook script's parent), for liveness and the exact jump.
    public var pid: Int32?
    public var tty: String?
    public var model: String?
    /// opencode's subagents are sessions with a parent.
    public var parentID: String?

    public init(provider: String, sessionID: String, kind: Kind, at: Date, cwd: String? = nil, pid: Int32? = nil,
                tty: String? = nil, model: String? = nil, parentID: String? = nil) {
        self.provider = provider
        self.sessionID = sessionID
        self.kind = kind
        self.at = at
        self.cwd = cwd
        self.pid = pid
        self.tty = tty
        self.model = model
        self.parentID = parentID
    }

    /// The session's id in the agents list.
    public var agentID: String { "\(provider):\(sessionID)" }

    /// A forwarded hook call; nil when it isn't one or names no session.
    public static func parse(_ data: Data, now: Date = Date()) -> HookUpdate? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let provider = object["starnotch_provider"] as? String,
              let event = (object["starnotch_event"] as? String)?.nilIfEmpty ?? (object["hook_event_name"] as? String)?.nilIfEmpty
        else { return nil }
        let fields = HookFields(object)
        let pid = fields.number("starnotch_pid").map { Int32(clamping: Int($0)) }.flatMap { $0 > 1 ? $0 : nil }
        let tty = fields.string("starnotch_tty").flatMap { TerminalJump.isSafe(tty: $0) ? $0 : nil }
        let kind: Kind?
        let session: String?
        var cwd = fields.string("cwd")
        var parent: String?
        switch provider {
        case CursorProvider.id:
            session = fields.string("conversation_id") ?? fields.string("session_id")
            cwd = cwd ?? fields.strings("workspace_roots").first
            kind = cursorKind(event, fields)
        case CopilotProvider.id:
            session = fields.string("sessionId") ?? fields.string("session_id")
            kind = copilotKind(event, fields)
        case GeminiProvider.id:
            session = fields.string("session_id")
            kind = geminiKind(event, fields)
        case OpencodeProvider.id:
            session = fields.string("session_id")
            parent = fields.string("parent_id")
            kind = opencodeKind(event, fields)
        default:
            return nil
        }
        guard let kind else { return nil }
        // A tool without session ids in its hooks (older Copilot CLI): the agent's process stands in.
        guard let id = session ?? pid.map({ "pid-\($0)" }) else { return nil }
        return HookUpdate(provider: provider, sessionID: id, kind: kind, at: now, cwd: cwd, pid: pid, tty: tty,
                          model: fields.string("model"), parentID: parent)
    }

    // MARK: Per tool

    /// Cursor's hooks.json events (agent in the editor and cursor-agent).
    static func cursorKind(_ event: String, _ f: HookFields) -> Kind? {
        switch event {
        case "sessionStart": return .started
        case "sessionEnd": return .ended
        case "beforeSubmitPrompt": return .prompt(f.string("prompt").map(short))
        case "beforeShellExecution", "afterShellExecution":
            return f.string("command").map { .tool(SessionStep(kind: .shell, text: short($0))) }
        case "beforeMCPExecution", "afterMCPExecution":
            return .tool(SessionStep(kind: .tool, text: f.string("tool_name") ?? "MCP"))
        case "afterFileEdit":
            return f.string("file_path").map { .tool(SessionStep(kind: .edit, text: "Editing " + ($0 as NSString).lastPathComponent)) }
        case "beforeReadFile":
            return f.string("file_path").map { .tool(SessionStep(kind: .read, text: "Reading " + ($0 as NSString).lastPathComponent)) }
        case "preToolUse", "postToolUse":
            return f.string("tool_name").map { .tool(step(tool: $0, input: f.object("tool_input"))) }
        case "afterAgentResponse": return .tool(SessionStep(kind: .message, text: short(f.string("text") ?? "")))
        case "stop": return .idle(nil)
        default: return nil
        }
    }

    /// GitHub Copilot CLI's hooks (the hook script names the event: its input doesn't).
    static func copilotKind(_ event: String, _ f: HookFields) -> Kind? {
        switch event.lowercased() {
        case "sessionstart": return .started
        case "sessionend": return .ended
        case "userpromptsubmitted", "userpromptsubmit": return .prompt(f.string("prompt").map(short))
        case "pretooluse", "posttooluse":
            guard let tool = f.string("toolName") ?? f.string("tool_name") else { return nil }
            return .tool(step(tool: tool, input: f.jsonObject("toolArgs") ?? f.object("tool_input")))
        case "permissionrequest":
            return .waiting("Approve: " + (f.string("toolName") ?? "a tool"))
        case "agentstop", "stop": return .idle(nil)
        case "erroroccurred": return .idle(f.object("error")?["message"] as? String)
        default: return nil
        }
    }

    /// Gemini CLI's hooks. It can only deny from a hook, so a permission prompt is shown, not answered.
    static func geminiKind(_ event: String, _ f: HookFields) -> Kind? {
        switch event {
        case "SessionStart": return .started
        case "SessionEnd": return .ended
        case "BeforeAgent": return .prompt(f.string("prompt").map(short))
        case "BeforeTool": return f.string("tool_name").map { .tool(step(tool: $0, input: f.object("tool_input"))) }
        case "AfterTool": return .answered
        case "AfterAgent": return .idle(f.string("prompt_response").map(short))
        case "Notification":
            guard f.string("notification_type") == "ToolPermission" else { return nil }
            return .waiting(short(f.string("message") ?? "Gemini asks for permission"))
        default: return nil
        }
    }

    /// What Starnotch's opencode plugin forwards (integrations/agents/opencode/starnotch.js).
    static func opencodeKind(_ event: String, _ f: HookFields) -> Kind? {
        switch event {
        case "session.created": return .started
        case "session.updated": return f.string("title").map { .title(short($0)) } ?? .started
        case "session.deleted": return .ended
        case "session.status":
            switch f.string("status") {
            case "busy", "retry": return .prompt(nil)
            case "idle": return .idle(nil)
            default: return nil
            }
        case "session.idle": return .idle(nil)
        case "tool": return f.string("tool").map { .tool(step(tool: $0, input: f.object("input"))) }
        case "permission.replied": return .answered
        default: return nil
        }
    }

    /// One step from a tool name and its input, in the words the agents list uses.
    static func step(tool: String, input: [String: Any]?) -> SessionStep {
        let input = input ?? [:]
        func value(_ keys: String...) -> String? {
            for key in keys { if let text = (input[key] as? String)?.nilIfEmpty { return text } }
            return nil
        }
        let name = tool.lowercased()
        if ["bash", "shell", "run_shell_command", "run_terminal_cmd", "exec", "command"].contains(name) {
            return SessionStep(kind: .shell, text: short(value("command", "cmd") ?? tool))
        }
        if name.contains("edit") || name.contains("write") || name == "replace" || name == "patch" || name == "apply_patch" {
            let file = value("file_path", "filePath", "path", "absolute_path").map { ($0 as NSString).lastPathComponent }
            return SessionStep(kind: .edit, text: file.map { "Editing " + $0 } ?? tool)
        }
        if name.contains("read") || name == "view" {
            let file = value("file_path", "filePath", "path", "absolute_path").map { ($0 as NSString).lastPathComponent }
            return SessionStep(kind: .read, text: file.map { "Reading " + $0 } ?? tool)
        }
        if name.contains("grep") || name.contains("glob") || name.contains("search") || name == "find" || name == "ls" {
            return SessionStep(kind: .search, text: short(value("pattern", "query", "path") ?? tool))
        }
        if name.contains("fetch") || name.contains("web") {
            return SessionStep(kind: .web, text: short(value("url", "query") ?? tool))
        }
        if name == "task" || name.contains("agent") {
            return SessionStep(kind: .agent, text: short(value("description", "prompt") ?? tool))
        }
        return SessionStep(kind: .tool, text: tool)
    }

    static func short(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 80 ? String(trimmed.prefix(79)) + "…" : trimmed
    }
}

/// Typed reads from a hook's JSON object.
struct HookFields {
    let object: [String: Any]
    init(_ object: [String: Any]) { self.object = object }

    func string(_ key: String) -> String? {
        (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    func strings(_ key: String) -> [String] { object[key] as? [String] ?? [] }

    func number(_ key: String) -> Double? {
        if let n = object[key] as? NSNumber { return n.doubleValue }
        return (object[key] as? String).flatMap(Double.init)
    }

    func object(_ key: String) -> [String: Any]? { object[key] as? [String: Any] }

    /// A field holding JSON as a string (Copilot's `toolArgs`).
    func jsonObject(_ key: String) -> [String: Any]? {
        if let nested = object[key] as? [String: Any] { return nested }
        guard let text = object[key] as? String else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
}

/// What the hooks said, per session, turned into agent sessions. Pure: the caller passes the
/// time and how to tell whether a process lives.
public struct HookSessions: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var provider: String
        public var sessionID: String
        public var cwd: String?
        public var title: String?
        public var firstPrompt: String?
        public var pid: Int32?
        public var tty: String?
        public var isBusy = false
        public var since: Date
        public var started: Date
        public var lastSeen: Date
        public var steps: [SessionStep] = []
        public var waiting: String?
        public var lastMessage: String?
        public var model: String?
        public var parentID: String?
    }

    /// A busy session without a hook call for this long stopped without saying so.
    public static let staleBusy: TimeInterval = 15 * 60
    /// A resting session stays this long after its last hook call (longer while its process lives).
    public static let recentWindow: TimeInterval = 30 * 60
    /// A session whose process still lives stays at most this long.
    public static let liveWindow: TimeInterval = 12 * 3600
    static let maxSteps = 8

    public private(set) var entries: [String: Entry] = [:]

    public init() {}

    public mutating func apply(_ update: HookUpdate) {
        let key = update.agentID
        if case .ended = update.kind {
            entries[key] = nil
            return
        }
        var entry = entries[key] ?? Entry(provider: update.provider, sessionID: update.sessionID, since: update.at,
                                          started: update.at, lastSeen: update.at)
        entry.lastSeen = max(entry.lastSeen, update.at)
        if let cwd = update.cwd { entry.cwd = cwd }
        if let pid = update.pid { entry.pid = pid }
        if let tty = update.tty { entry.tty = tty }
        if let model = update.model { entry.model = model }
        if let parent = update.parentID { entry.parentID = parent }
        func work() {
            if !entry.isBusy { entry.isBusy = true; entry.since = update.at }
        }
        switch update.kind {
        case .started:
            break
        case .prompt(let prompt):
            if let prompt, !prompt.isEmpty, entry.firstPrompt == nil { entry.firstPrompt = prompt }
            entry.waiting = nil
            work()
        case .tool(var step):
            step.date = update.at
            entry.steps.append(step)
            if entry.steps.count > Self.maxSteps { entry.steps.removeFirst(entry.steps.count - Self.maxSteps) }
            entry.waiting = nil
            work()
        case .waiting(let reason):
            entry.waiting = reason
            entry.isBusy = false
            entry.since = update.at
        case .answered:
            if entry.waiting != nil { entry.waiting = nil; work() }
        case .idle(let message):
            if let message, !message.isEmpty { entry.lastMessage = message }
            entry.waiting = nil
            if entry.isBusy { entry.isBusy = false; entry.since = update.at }
        case .title(let title):
            entry.title = title
        case .ended:
            break
        }
        entries[key] = entry
    }

    /// Drops what's over (dead processes, old sessions) and returns the rest of `provider`'s sessions.
    public mutating func sessions(provider: String, now: Date, isAlive: (Int32) -> Bool) -> [AgentSession] {
        var result: [AgentSession] = []
        let mine = entries.filter { $0.value.provider == provider }
        let children = Dictionary(grouping: mine.values.filter { $0.parentID != nil }) { $0.parentID! }
        for (key, entry) in mine {
            let quiet = now.timeIntervalSince(entry.lastSeen)
            let alive = entry.pid.map(isAlive)
            if alive == false || quiet > Self.liveWindow || (alive == nil && quiet > Self.recentWindow && !entry.isBusy)
                || (alive == nil && quiet > Self.staleBusy + Self.recentWindow) {
                entries[key] = nil
                continue
            }
            guard entry.parentID == nil else { continue }
            let busy = entry.isBusy && quiet < Self.staleBusy
            let cwd = entry.cwd ?? ""
            let subs = (children[entry.sessionID] ?? []).sorted { $0.lastSeen > $1.lastSeen }
            let shown = subs.prefix(5).map { child -> AgentSubagent in
                let running = child.isBusy && now.timeIntervalSince(child.lastSeen) < Self.staleBusy
                var progress = SubagentProgress()
                progress.steps = child.steps
                progress.startedAt = child.started
                progress.lastDate = child.lastSeen
                return AgentSubagent(id: "\(provider):\(child.sessionID)", name: child.title ?? child.firstPrompt ?? "Subagent",
                                     step: running ? child.steps.last?.text : nil, agentType: provider,
                                     status: running ? .running : .done, modified: child.lastSeen, progress: progress)
            }
            result.append(AgentSession(
                id: "\(provider):\(entry.sessionID)",
                project: cwd.isEmpty ? provider : ProjectPaths.projectName(ofCwd: cwd),
                title: entry.title ?? entry.firstPrompt,
                cwd: cwd.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : cwd,
                pid: entry.pid,
                isBusy: busy,
                // Busy gone stale: it rests since the last word it said.
                since: entry.isBusy && !busy ? entry.lastSeen : entry.since,
                steps: entry.steps,
                subagents: Array(shown),
                earlierSubagents: max(0, subs.count - shown.count),
                started: entry.started,
                lastMessage: entry.lastMessage,
                model: entry.model,
                provider: provider,
                needsYou: entry.waiting,
                tty: entry.tty))
        }
        return SessionMerge.ordered(result)
    }
}

/// Puts the hooks' view over the files' view of the same tool: a session both know keeps the
/// files' details and takes the hooks' state; a session only one knows is shown as it is.
public enum HookOverlay {
    public static func merge(files: [AgentSession], hooks: [AgentSession]) -> [AgentSession] {
        let live = Dictionary(hooks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var merged = files.map { file -> AgentSession in
            guard let hook = live[file.id] else { return file }
            var session = file
            session.isBusy = hook.isBusy
            session.since = hook.since ?? file.since
            session.needsYou = hook.needsYou
            if !hook.steps.isEmpty { session.steps = hook.steps }
            session.pid = hook.pid ?? file.pid
            session.tty = hook.tty ?? file.tty
            session.title = file.title ?? hook.title
            if session.subagents.isEmpty { session.subagents = hook.subagents }
            return session
        }
        let known = Set(files.map(\.id))
        merged += hooks.filter { !known.contains($0.id) }
        return SessionMerge.ordered(merged)
    }
}

/// What every hook-driven provider shares: the hooks' sessions over the files' sessions, and
/// running CLIs nobody reported yet (shown resting, so a click still finds their terminal).
public struct HookedTool: Sendable {
    public var hooks = HookSessions()
    let names: Set<String>
    let scripts: [String]
    let useProcesses: Bool
    private var processes: [Processes.AgentProcess] = []
    private var processesAt = Date.distantPast

    public init(names: Set<String>, scripts: [String] = [], useProcesses: Bool = true) {
        self.names = names
        self.scripts = scripts
        self.useProcesses = useProcesses
    }

    public mutating func sessions(provider: String, now: Date, files: [AgentSession] = [],
                                  isAlive: (Int32) -> Bool = ClaudeCodeProvider.isAlive) -> [AgentSession] {
        let hooked = hooks.sessions(provider: provider, now: now, isAlive: isAlive)
        var merged = HookOverlay.merge(files: files, hooks: hooked)
        if useProcesses, now.timeIntervalSince(processesAt) > 15 {
            processes = Processes.agents(names: names, scripts: scripts)
            processesAt = now
        }
        return SessionMerge.ordered(Self.adding(processes, to: &merged, provider: provider))
    }

    /// Fills pid and terminal of sessions in a running CLI's folder; a CLI in a folder no session
    /// knows becomes a resting session of its own.
    static func adding(_ processes: [Processes.AgentProcess], to sessions: inout [AgentSession], provider: String) -> [AgentSession] {
        func resolved(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path }
        var claimedPids = Set(sessions.compactMap(\.pid))
        for process in processes where !claimedPids.contains(process.pid) {
            guard let cwd = process.cwd else { continue }
            let folder = resolved(cwd)
            if let index = sessions.firstIndex(where: { $0.pid == nil && resolved($0.cwd) == folder }) {
                sessions[index].pid = process.pid
                if sessions[index].tty == nil { sessions[index].tty = process.tty }
            } else if !sessions.contains(where: { resolved($0.cwd) == folder }) {
                sessions.append(AgentSession(id: "\(provider):pid-\(process.pid)", project: ProjectPaths.projectName(ofCwd: cwd),
                                             cwd: cwd, pid: process.pid, isBusy: false, provider: provider, tty: process.tty))
            }
            claimedPids.insert(process.pid)
        }
        return sessions
    }
}

/// Optional: a provider whose sessions come (also) from hooks the notch receives.
public protocol HookSessionSource: AgentProvider {
    func ingest(_ update: HookUpdate) async
}
