import Foundation

/// Codex sessions (CLI, desktop app and IDE extension): the thread list in `state_5.sqlite`
/// (title, folder, branch, model, subagents), each thread's rollout JSONL (working or done,
/// steps, tokens, context window, plan limits) and the process list (pid and terminal of CLI
/// sessions). Read-only: SQLite in `mode=ro`, rollouts from their last offset. A rollout of an
/// unknown shape switches the provider off with a note instead of showing guesses.
public actor CodexProvider: AgentProvider, UsageProvider, AgentEventSource, ApprovalProvider {
    public static let id = "codex"
    public static let displayName = "Codex"

    public static var defaultRoot: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex") }

    public static func detect() -> Bool {
        FileManager.default.fileExists(atPath: defaultRoot.appending(path: "sessions").path)
    }

    /// Threads changed this recently are candidates; shown when working, recent or running.
    static let candidateWindow: TimeInterval = 6 * 3600
    /// A resting session stays this long after its last write (Codex keeps no live registry).
    static let recentWindow: TimeInterval = 30 * 60
    /// "Working" without a write for this long means the turn died without a record.
    static let staleWorking: TimeInterval = 15 * 60
    static let maxSessions = 6
    static let maxRead: UInt64 = 8 * 1024 * 1024

    public nonisolated let root: URL

    struct Thread: Equatable {
        var id: String
        var rolloutPath: String
        var cwd: String?
        var name: String?
        var title: String?
        var branch: String?
        var model: String?
        var effort: String?
        var nickname: String?
        var agentPath: String?
        var created: Date?
    }

    private var reads: [String: (offset: UInt64, rollout: CodexRollout)] = [:]
    private var threads: [Thread] = []
    private var threadsStamp: Date?
    private var latestLimits: CodexRollout.Limits?
    /// Process lookup for terminals, every few scans only.
    private var processes: [(pid: Int32, cwd: String?, tty: String?)] = []
    private var processesAt = Date.distantPast
    /// Last modification of each session's rollout, for event precedence.
    public private(set) var fileTimes: [String: Date] = [:]
    /// The process list is a fallback; tests turn it off.
    private let useProcesses: Bool

    public init(root: URL = CodexProvider.defaultRoot, useProcesses: Bool = true) {
        self.root = root
        self.useProcesses = useProcesses
    }

    public nonisolated var watchPaths: [URL] { [root.appending(path: "sessions"), root] }

    // MARK: Scan

    public func scan(now: Date) async -> ProviderScan {
        let candidates = candidateThreads(now: now)
        var rollouts: [(Thread, CodexRollout, Date)] = []
        for thread in candidates {
            let url = URL(fileURLWithPath: thread.rolloutPath)
            guard let mtime = ClaudeCodeProvider.mtime(url) else { continue }
            let rollout = read(url)
            if rollout.formatLooksUnknown {
                return ProviderScan(sessions: [], unsupported: "Codex's session files have a shape this version doesn't know (\(url.lastPathComponent)).")
            }
            rollouts.append((thread, rollout, mtime))
            if let limits = rollout.limits, limits.at > (latestLimits?.at ?? .distantPast) { latestLimits = limits }
        }
        if useProcesses, now.timeIntervalSince(processesAt) > 15 {
            processes = Processes.named("codex")
            processesAt = now
        }
        return ProviderScan(sessions: sessions(from: rollouts, now: now))
    }

    func sessions(from rollouts: [(Thread, CodexRollout, Date)], now: Date) -> [AgentSession] {
        // Subagents hang under their parent; the automatic reviewer isn't shown.
        let children = Dictionary(grouping: rollouts.filter { !$0.1.isGuardian && $0.1.parentThreadID != nil }) { $0.1.parentThreadID! }
        let liveCwds = Dictionary(processes.compactMap { p in p.cwd.map { (Self.resolved($0), p) } }, uniquingKeysWith: { a, _ in a })
        var sessions: [AgentSession] = []
        var claimedCwds = Set<String>()
        for (thread, rollout, mtime) in rollouts.sorted(by: { $0.2 > $1.2 }) {
            guard !rollout.isGuardian, rollout.parentThreadID == nil else { continue }
            let threadID = rollout.threadID ?? thread.id
            let cwd = rollout.cwd ?? thread.cwd ?? root.path
            let fresh = now.timeIntervalSince(mtime) < Self.staleWorking
            let working = rollout.phase == .working && fresh
            var live = liveCwds[Self.resolved(cwd)]
            if live != nil, claimedCwds.contains(Self.resolved(cwd)) { live = nil }
            guard working || now.timeIntervalSince(mtime) < Self.recentWindow || live != nil else { continue }
            if live != nil { claimedCwds.insert(Self.resolved(cwd)) }
            let subs = (children[threadID] ?? []).sorted { $0.2 > $1.2 }
            let shown = subs.prefix(5).map { child -> AgentSubagent in
                let (childThread, childRollout, childTime) = child
                let running = childRollout.phase == .working && now.timeIntervalSince(childTime) < Self.staleWorking
                let status: SubagentProgress.Status = running ? .running : childRollout.phase == .aborted ? .stopped : .done
                let name = childRollout.nickname ?? childThread.nickname
                    ?? childThread.agentPath.map { ($0 as NSString).lastPathComponent.replacingOccurrences(of: "_", with: " ") }
                    ?? "Subagent"
                var progress = SubagentProgress()
                progress.task = childThread.agentPath.map { ($0 as NSString).lastPathComponent.replacingOccurrences(of: "_", with: " ") }
                progress.startedAt = childRollout.startedAt
                progress.lastDate = childRollout.lastDate
                progress.steps = childRollout.steps
                return AgentSubagent(id: "codex:" + (childRollout.threadID ?? childThread.id), name: name,
                                     step: running ? childRollout.steps.last?.text : nil, agentType: "codex",
                                     status: status, modified: childTime, progress: progress)
            }
            let id = "codex:" + threadID
            fileTimes[id] = mtime
            let effort = rollout.effort ?? thread.effort
            sessions.append(AgentSession(
                id: id,
                project: ProjectPaths.projectName(ofCwd: cwd),
                title: thread.name ?? thread.title.map { CodexRollout.short($0, 80) } ?? rollout.firstPrompt,
                cwd: cwd,
                pid: live?.pid,
                isBusy: working,
                since: rollout.phaseSince ?? rollout.lastDate ?? mtime,
                steps: rollout.steps,
                subagents: Array(shown),
                earlierSubagents: max(0, subs.count - shown.count),
                branch: thread.branch ?? rollout.branch,
                started: rollout.startedAt ?? thread.created,
                lastMessage: rollout.lastMessage,
                level: effort.flatMap(PerformanceLevel.init(effort:)),
                model: rollout.model ?? thread.model,
                effort: effort,
                contextTokens: rollout.contextTokens,
                provider: Self.id,
                contextWindow: rollout.contextWindow,
                tty: live?.tty))
            if sessions.count >= Self.maxSessions { break }
        }
        return SessionMerge.ordered(sessions)
    }

    static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    // MARK: Threads

    /// Recently changed threads from the database; without it (missing, locked, unknown
    /// columns), the newest rollout files.
    func candidateThreads(now: Date) -> [Thread] {
        let database = root.appending(path: "state_5.sqlite")
        let stamp = [database, root.appending(path: "state_5.sqlite-wal")].compactMap(ClaudeCodeProvider.mtime).max()
        // The database didn't change: the last answer stands (an empty one too).
        if let stamp, stamp == threadsStamp { return threads.filter { Self.isRecent($0, now: now) } }
        if let rows = Self.threadRows(database: database.path, since: now.addingTimeInterval(-Self.candidateWindow)) {
            threads = rows
            threadsStamp = stamp
            return rows.filter { Self.isRecent($0, now: now) }
        }
        threads = rolloutFiles(now: now)
        threadsStamp = nil
        return threads
    }

    static func isRecent(_ thread: Thread, now: Date) -> Bool {
        let mtime = ClaudeCodeProvider.mtime(URL(fileURLWithPath: thread.rolloutPath)) ?? .distantPast
        return now.timeIntervalSince(mtime) < candidateWindow
    }

    static func threadRows(database: String, since: Date) -> [Thread]? {
        guard let db = SQLiteReader(path: database) else { return nil }
        let columns = db.columns(of: "threads")
        guard ["id", "rollout_path", "updated_at"].allSatisfy(columns.contains) else { return nil }
        let wanted = ["id", "rollout_path", "cwd", "title", "name", "git_branch", "model", "reasoning_effort",
                      "agent_nickname", "agent_path", "created_at", "archived", "updated_at"].filter(columns.contains)
        var sql = "SELECT \(wanted.joined(separator: ", ")) FROM threads WHERE updated_at >= ?"
        if columns.contains("archived") { sql += " AND archived = 0" }
        sql += " ORDER BY updated_at DESC LIMIT 60"
        return db.rows(sql, [String(Int(since.timeIntervalSince1970))]).compactMap { row -> Thread? in
            guard let id = row["id"] ?? nil, let path = row["rollout_path"] ?? nil else { return nil }
            func text(_ key: String) -> String? { (row[key] ?? nil)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
            return Thread(id: id, rolloutPath: path, cwd: text("cwd"), name: text("name"), title: text("title"),
                          branch: text("git_branch"), model: text("model"), effort: text("reasoning_effort"),
                          nickname: text("agent_nickname"), agentPath: text("agent_path"),
                          created: text("created_at").flatMap(Double.init).map { Date(timeIntervalSince1970: $0) })
        }
    }

    /// Rollouts of today and yesterday changed within the candidate window.
    func rolloutFiles(now: Date) -> [Thread] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var result: [(Thread, Date)] = []
        for offset in [0, -1] {
            let day = now.addingTimeInterval(Double(offset) * 86_400)
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let dir = root.appending(path: String(format: "sessions/%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0))
            for file in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            where file.pathExtension == "jsonl" {
                guard let mtime = ClaudeCodeProvider.mtime(file), now.timeIntervalSince(mtime) < Self.candidateWindow else { continue }
                // rollout-2026-10-20T13-52-48-<uuid>.jsonl
                let name = file.deletingPathExtension().lastPathComponent
                let id = name.count > 36 ? String(name.suffix(36)) : name
                result.append((Thread(id: id, rolloutPath: file.path), mtime))
            }
        }
        return result.sorted { $0.1 > $1.1 }.prefix(40).map(\.0)
    }

    // MARK: Rollouts

    /// New complete lines since the last read. A very long rollout seen for the first time:
    /// its head (the session's metadata) and its last 2 MB.
    func read(_ url: URL) -> CodexRollout {
        var entry = reads[url.path] ?? (0, CodexRollout())
        guard let handle = try? FileHandle(forReadingFrom: url) else { return entry.rollout }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < entry.offset { entry = (0, CodexRollout()) }
        guard size > entry.offset else { return entry.rollout }
        if entry.offset == 0, size > Self.maxRead {
            try? handle.seek(toOffset: 0)
            let head = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
            if let cut = head.firstIndex(of: 0x0A) {
                entry.rollout.feed(lines: Substring(String(decoding: head[head.startIndex..<cut], as: UTF8.self)))
            }
            let window: UInt64 = 2 * 1024 * 1024
            try? handle.seek(toOffset: size - window)
            let tail = (try? handle.read(upToCount: Int(window))) ?? Data()
            if let first = tail.firstIndex(of: 0x0A), let last = tail.lastIndex(of: 0x0A), first < last {
                entry.rollout.feed(lines: Substring(String(decoding: tail[tail.index(after: first)...last], as: UTF8.self)))
                entry.offset = size - window + UInt64(tail.distance(from: tail.startIndex, to: last) + 1)
            } else {
                entry.offset = size
            }
            reads[url.path] = entry
            return entry.rollout
        }
        try? handle.seek(toOffset: entry.offset)
        let data = (try? handle.read(upToCount: Int(size - entry.offset))) ?? Data()
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return entry.rollout }
        let complete = data[data.startIndex...lastNewline]
        entry.rollout.feed(lines: Substring(String(decoding: complete, as: UTF8.self)))
        entry.offset += UInt64(complete.count)
        reads[url.path] = entry
        return entry.rollout
    }

    // MARK: Usage

    /// The newest plan limits Codex reported (`token_count.rate_limits`), as `/status` shows them.
    public func usage(now: Date) async -> AgentUsage? {
        if latestLimits == nil {
            // Nothing recent: the newest thread's rollout still has the last known limits.
            // Nothing recent: the newest threads' rollouts still have the last known limits.
            let newest = (Self.threadRows(database: root.appending(path: "state_5.sqlite").path, since: .distantPast)
                ?? rolloutFiles(now: now)).prefix(3)
            for thread in newest {
                var rollout = CodexRollout()
                rollout.feed(lines: Substring(ClaudeCodeProvider.tail(of: URL(fileURLWithPath: thread.rolloutPath), bytes: 512 * 1024)))
                if let limits = rollout.limits, limits.at > (latestLimits?.at ?? .distantPast) { latestLimits = limits }
            }
        }
        guard let limits = latestLimits else { return nil }
        return AgentUsage(provider: Self.id, displayName: Self.displayName, primary: limits.primary,
                          secondary: limits.secondary, plan: limits.plan, capturedAt: limits.at).current(now: now)
    }

    // MARK: Hooks and approvals

    /// A PermissionRequest forwarded by the hook script: the session waits for an approval.
    public nonisolated func parse(hook payload: Data) -> AgentEvent? {
        guard let request = ApprovalRequest.parse(payload), request.provider == Self.id, let session = request.sessionID else { return nil }
        return AgentEvent(sessionID: "codex:" + session, kind: .needsApproval("Approve: " + request.summary), at: Date())
    }

    /// Where the approvals integration lives (the app bundle's copy, or the repository's).
    public nonisolated(unsafe) static var integrationFolder = "integrations/claude-code/starnotch-approvals"

    public nonisolated var approvalSetup: IntegrationSetup {
        let script = "\"\(Self.integrationFolder)/codex/install-hook.sh\""
        return IntegrationSetup(
            title: "Codex approvals in the notch",
            install: script,
            remove: script + " --remove",
            note: "Adds one PermissionRequest hook to ~/.codex/hooks.json (a backup is kept). Review it once with /hooks in Codex.")
    }

    public nonisolated func reply(to request: ApprovalRequest, with decision: ApprovalDecision) -> Data {
        ApprovalFormat.codex(decision)
    }
}
