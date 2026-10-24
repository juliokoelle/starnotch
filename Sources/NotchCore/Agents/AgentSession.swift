import Foundation

/// One agent session on this Mac, whatever tool runs it (Claude Code, Codex …). Providers build
/// these; the agents module shows them.
public struct AgentSession: Equatable, Sendable, Identifiable {
    /// Unique across providers: Claude Code keeps its bare session id, others are "<provider>:<id>".
    public var id: String
    /// Project folder, e.g. "notch-switcher".
    public var project: String
    /// Session title (user-given or generated).
    public var title: String?
    public var cwd: String
    public var pid: Int32?
    public var isBusy: Bool
    /// Start of the current busy or idle phase.
    public var since: Date?
    public var steps: [SessionStep]
    /// The most recent subagents (up to five), newest first.
    public var subagents: [AgentSubagent]
    /// Older subagents not in `subagents`.
    public var earlierSubagents: Int
    /// Git branch of the session's working copy.
    public var branch: String?
    /// When the session started, for ordering sessions of one project.
    public var started: Date?
    /// claude.ai/code/<id> for Remote Control sessions.
    public var remoteURL: URL?
    public var lastMessage: String?
    /// Latest effort (and model) of the session, for the colour scale.
    public var level: PerformanceLevel?
    public var model: String?
    public var effort: String?
    /// Tokens in the context at the last message.
    public var contextTokens: Int?
    /// Recordings only: a fixed context percentage.
    public var contextPercentage: Double?
    /// Which tool runs it: `ClaudeCodeProvider.id`, `CodexProvider.id` …
    public var provider: String
    /// Size of the context window when the tool reports it (Codex), for an exact percentage.
    public var contextWindow: Int?
    /// The tool says the session needs the user (an approval waits, the desktop app's
    /// "needs action"): the reason, shown as its line.
    public var needsYou: String?
    /// Terminal device of the session's process ("/dev/ttys003"), for jumping to its tab.
    public var tty: String?

    public init(id: String, project: String, title: String? = nil, cwd: String, pid: Int32? = nil, isBusy: Bool,
                since: Date? = nil, steps: [SessionStep] = [], subagents: [AgentSubagent] = [], earlierSubagents: Int = 0,
                branch: String? = nil, started: Date? = nil, remoteURL: URL? = nil, lastMessage: String? = nil,
                level: PerformanceLevel? = nil, model: String? = nil, effort: String? = nil, contextTokens: Int? = nil,
                contextPercentage: Double? = nil, provider: String = "claude-code", contextWindow: Int? = nil,
                needsYou: String? = nil, tty: String? = nil) {
        self.id = id
        self.project = project
        self.title = title
        self.cwd = cwd
        self.pid = pid
        self.isBusy = isBusy
        self.since = since
        self.steps = steps
        self.subagents = subagents
        self.earlierSubagents = earlierSubagents
        self.branch = branch
        self.started = started
        self.remoteURL = remoteURL
        self.lastMessage = lastMessage
        self.level = level
        self.model = model
        self.effort = effort
        self.contextTokens = contextTokens
        self.contextPercentage = contextPercentage
        self.provider = provider
        self.contextWindow = contextWindow
        self.needsYou = needsYou
        self.tty = tty
    }

    /// The name to show: the user's own, else the generated title, else the project.
    public var displayTitle: String { title ?? project }
}

/// A subagent of a session (Claude Code's Task agents, Codex's spawned threads).
public struct AgentSubagent: Equatable, Sendable, Identifiable {
    public var id: String
    /// The parent's description of it ("Push reminders").
    public var name: String
    /// Its current step while running.
    public var step: String?
    public var agentType: String?
    public var status: SubagentProgress.Status
    /// Last change of its transcript.
    public var modified: Date?
    public var progress: SubagentProgress

    public init(id: String, name: String, step: String? = nil, agentType: String? = nil,
                status: SubagentProgress.Status = .running, modified: Date? = nil, progress: SubagentProgress = SubagentProgress()) {
        self.id = id
        self.name = name
        self.step = step
        self.agentType = agentType
        self.status = status
        self.modified = modified
        self.progress = progress
    }
}
