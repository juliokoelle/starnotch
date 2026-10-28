import Foundation

// Every agent tool is a provider of the same shape; the agents module only knows these protocols.
// Built like the connector API (`NotchConnector` plus capabilities), so others can ship a provider
// as a Swift package.

/// A tool whose sessions the notch follows.
public protocol AgentProvider: AnyObject, Sendable {
    /// "claude-code", "codex" …
    static var id: String { get }
    static var displayName: String { get }
    /// The tool is on this Mac (its folder exists, its app is installed).
    static func detect() -> Bool
    /// Folders whose changes should trigger a scan (watched with FSEvents or a kqueue).
    var watchPaths: [URL] { get }
    /// Reads only what changed since the last call (offsets per file) and returns the sessions.
    func scan(now: Date) async -> ProviderScan
}

/// What a scan found, and whether the provider still understands the tool's files.
public struct ProviderScan: Equatable, Sendable {
    public var sessions: [AgentSession]
    /// Set when the format is unknown: the provider shows nothing rather than something wrong.
    public var unsupported: String?

    public init(sessions: [AgentSession], unsupported: String? = nil) {
        self.sessions = sessions
        self.unsupported = unsupported
    }
}

/// Optional: live events (hooks, plugins). They beat what the files say.
public protocol AgentEventSource: AgentProvider {
    /// The event in a hook's JSON; nil when it isn't this provider's.
    func parse(hook payload: Data) -> AgentEvent?
}

/// Optional: answers permission prompts from the island.
public protocol ApprovalProvider: AgentProvider {
    /// What to install and how to remove it again; the user runs it, the app never writes it.
    var approvalSetup: IntegrationSetup { get }
    /// What the hook script prints on stdout (each tool has its own format).
    func reply(to request: ApprovalRequest, with decision: ApprovalDecision) -> Data
}

/// Optional: plan limits without credentials.
public protocol UsageProvider: AgentProvider {
    func usage(now: Date) async -> AgentUsage?
}

/// Optional: brings the session to the front (terminal tab, editor window, app).
public protocol SessionOpener: AgentProvider {
    func open(_ session: AgentSession) -> Bool
}

/// A hook event for one session.
public struct AgentEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A permission prompt waits (the reason: "Approve: npm test").
        case needsApproval(String)
        /// The prompt was answered or went away.
        case approvalDone
        case working
        case idle
    }

    /// Starts the reason of every `needsApproval`: a block the notch's own prompts answer.
    public static let approvalPrefix = "Approve: "

    /// The session's id as `AgentSession.id`.
    public var sessionID: String
    public var kind: Kind
    public var at: Date

    public init(sessionID: String, kind: Kind, at: Date) {
        self.sessionID = sessionID
        self.kind = kind
        self.at = at
    }
}

/// Plan limits of one tool.
public struct AgentUsage: Equatable, Sendable {
    public struct Window: Equatable, Sendable {
        /// 0...100
        public var usedPercent: Double
        public var minutes: Int?
        public var resetsAt: Date?

        public init(usedPercent: Double, minutes: Int?, resetsAt: Date?) {
            self.usedPercent = usedPercent
            self.minutes = minutes
            self.resetsAt = resetsAt
        }

        /// "5 h", "week", "90 m".
        public var label: String {
            guard let minutes else { return "" }
            // Older Codex versions report 299 and 10079 minutes.
            if minutes >= 7 * 24 * 60 - 60 { return "week" }
            let hours = (Double(minutes) / 60).rounded()
            if hours >= 1, abs(Double(minutes) - hours * 60) <= 5 { return "\(Int(hours)) h" }
            return "\(minutes) m"
        }
    }

    public var provider: String
    public var displayName: String
    /// The short window (five hours) and the long one (a week).
    public var primary: Window?
    public var secondary: Window?
    public var plan: String?
    public var capturedAt: Date

    public init(provider: String, displayName: String, primary: Window?, secondary: Window?, plan: String? = nil, capturedAt: Date) {
        self.provider = provider
        self.displayName = displayName
        self.primary = primary
        self.secondary = secondary
        self.plan = plan
        self.capturedAt = capturedAt
    }

    /// The fuller of the two windows, for ordering.
    public var peak: Double { max(primary?.usedPercent ?? 0, secondary?.usedPercent ?? 0) }

    /// A window whose reset time has passed starts again from zero.
    public func current(now: Date) -> AgentUsage {
        func fresh(_ window: Window?) -> Window? {
            guard var window else { return nil }
            if let reset = window.resetsAt, reset <= now { window.usedPercent = 0; window.resetsAt = nil }
            return window
        }
        var copy = self
        copy.primary = fresh(primary)
        copy.secondary = fresh(secondary)
        return copy
    }

    /// Several tools side by side: the one closest to its limit first.
    public static func ordered(_ usages: [AgentUsage]) -> [AgentUsage] {
        usages.sorted { $0.peak != $1.peak ? $0.peak > $1.peak : $0.provider < $1.provider }
    }
}

/// A visible, reversible setup step for the user (never run by the app).
public struct IntegrationSetup: Equatable, Sendable {
    public var title: String
    public var install: String
    public var remove: String
    public var note: String?

    public init(title: String, install: String, remove: String, note: String? = nil) {
        self.title = title
        self.install = install
        self.remove = remove
        self.note = note
    }
}

/// Combines what the sources say about a session. Precedence: a hook event beats the files,
/// the files beat the process list (which only fills gaps such as the pid and terminal).
public enum SessionMerge {
    /// Applies hook events newer than the files' view of each session.
    public static func apply(_ events: [AgentEvent], to sessions: [AgentSession], fileTimes: [String: Date] = [:]) -> [AgentSession] {
        let latest = Dictionary(events.map { ($0.sessionID, $0) }, uniquingKeysWith: { a, b in a.at >= b.at ? a : b })
        return sessions.map { session in
            guard let event = latest[session.id] else { return session }
            // A working/idle event older than the session's files is stale: the files win then.
            // A pending approval holds until its hook ends (the files can't see it at all).
            if event.kind == .working || event.kind == .idle,
               let written = fileTimes[session.id], written > event.at { return session }
            var merged = session
            switch event.kind {
            case .needsApproval(let reason):
                merged.needsYou = reason
                merged.isBusy = false
                merged.since = event.at
            case .approvalDone:
                merged.needsYou = nil
            case .working:
                if !merged.isBusy { merged.isBusy = true; merged.since = event.at }
            case .idle:
                if merged.isBusy { merged.isBusy = false; merged.since = event.at }
            }
            return merged
        }
    }

    /// Fills pid and terminal from the process list where the files don't know them.
    public static func fill(_ sessions: [AgentSession], processes: [String: (pid: Int32, tty: String?)]) -> [AgentSession] {
        sessions.map { session in
            guard let process = processes[session.id] else { return session }
            var merged = session
            if merged.pid == nil { merged.pid = process.pid }
            if merged.tty == nil { merged.tty = process.tty }
            return merged
        }
    }

    /// Working first, then the most recent change.
    public static func ordered(_ sessions: [AgentSession]) -> [AgentSession] {
        sessions.sorted {
            if $0.isBusy != $1.isBusy { return $0.isBusy }
            return ($0.since ?? .distantPast) > ($1.since ?? .distantPast)
        }
    }
}
