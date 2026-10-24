import Darwin
import Foundation

/// Claude Code sessions: the live registry (`~/.claude/sessions/<pid>.json`), each session's
/// transcript and subagents (`~/.claude/projects/**`), and, when the Claude app is installed, its
/// desktop session files for better titles and the "needs action" flag. Read-only; transcripts
/// are cached by modification time and subagent transcripts read from their last offset.
public actor ClaudeCodeProvider: AgentProvider {
    public static let id = "claude-code"
    public static let displayName = "Claude Code"

    public static func detect() -> Bool {
        FileManager.default.fileExists(atPath: defaultRoot.path)
    }

    public static var defaultRoot: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude") }

    /// A session file written to this recently counts as active even without a live process entry.
    static let recentWindow: TimeInterval = 180
    static let tailBytes = 384 * 1024
    static let subagentsShown = 5

    public nonisolated let root: URL
    /// The Claude app's desktop sessions; nil leaves them out.
    public nonisolated let desktop: ClaudeDesktop?

    private var tails: [String: (mtime: Date, activity: SessionActivity)] = [:]
    private var subagentMeta: [String: SubagentMeta] = [:]
    /// Per subagent transcript: bytes read so far and what they said.
    private var subagentReads: [String: (offset: UInt64, progress: SubagentProgress)] = [:]
    /// Last modification of each session's transcript, for event precedence.
    public private(set) var fileTimes: [String: Date] = [:]

    public init(root: URL = ClaudeCodeProvider.defaultRoot, desktop: ClaudeDesktop? = ClaudeDesktop()) {
        self.root = root
        self.desktop = desktop
    }

    public nonisolated var watchPaths: [URL] {
        [root.appending(path: "sessions")] + (desktop.map { [$0.root] } ?? [])
    }

    public func scan(now: Date) async -> ProviderScan {
        ProviderScan(sessions: scanSessions(now: now))
    }

    private func scanSessions(now: Date) -> [AgentSession] {
        let fm = FileManager.default
        var agents: [AgentSession] = []
        var seen = Set<String>()
        let desktopSessions = desktop?.sessions() ?? [:]

        let registry = root.appending(path: "sessions")
        let records = ((try? fm.contentsOfDirectory(at: registry, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap(SessionRecord.decode) }
            .filter { !$0.isBackgroundHelper && Self.isAlive($0.pid) }

        for record in records {
            seen.insert(record.sessionId)
            let file = transcript(for: record)
            if let file, let mtime = Self.mtime(file) { fileTimes[record.sessionId] = mtime }
            let subs = file.map { subagents(of: $0, now: now) }
            let activity = file.map { self.activity(of: $0) } ?? SessionActivity()
            var session = AgentSession(
                id: record.sessionId,
                project: ProjectPaths.projectName(ofCwd: record.cwd),
                title: record.userName ?? activity.title ?? activity.firstPrompt,
                cwd: activity.cwd ?? record.cwd,
                pid: record.pid,
                isBusy: record.isBusy,
                since: record.statusSince,
                steps: activity.steps,
                subagents: subs?.shown ?? [],
                earlierSubagents: subs?.earlier ?? 0,
                branch: activity.branch,
                started: record.startedAt.map { Date(timeIntervalSince1970: $0 / 1000) },
                remoteURL: record.remoteURL,
                lastMessage: activity.lastMessage,
                level: activity.effort.flatMap(PerformanceLevel.init(effort:)),
                model: activity.model,
                effort: activity.effort,
                contextTokens: activity.contextTokens,
                provider: Self.id,
                tty: Processes.tty(of: record.pid)
            )
            if let desk = desktopSessions[record.sessionId] {
                session = desk.enrich(session, userNamed: record.userName != nil)
            }
            agents.append(session)
        }

        // Fallback: transcripts written in the last few minutes without a live registry entry.
        let projects = root.appending(path: "projects")
        for dir in (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [] {
            guard !dir.lastPathComponent.contains("claude-mem") else { continue }
            for file in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            where file.pathExtension == "jsonl" {
                let id = file.deletingPathExtension().lastPathComponent
                guard !seen.contains(id), let mtime = Self.mtime(file),
                      now.timeIntervalSince(mtime) < Self.recentWindow else { continue }
                fileTimes[id] = mtime
                let activity = activity(of: file)
                let cwd = activity.cwd ?? dir.lastPathComponent
                var session = AgentSession(
                    id: id, project: ProjectPaths.projectName(ofCwd: cwd), title: activity.title ?? activity.firstPrompt, cwd: cwd, pid: nil,
                    isBusy: now.timeIntervalSince(mtime) < 45, since: activity.lastDate ?? mtime,
                    steps: activity.steps, subagents: subagents(of: file, now: now).shown,
                    branch: activity.branch,
                    lastMessage: activity.lastMessage,
                    level: activity.effort.flatMap(PerformanceLevel.init(effort:)),
                    model: activity.model, effort: activity.effort, contextTokens: activity.contextTokens,
                    provider: Self.id
                )
                if let desk = desktopSessions[id] { session = desk.enrich(session, userNamed: false) }
                agents.append(session)
            }
        }
        return SessionMerge.ordered(agents)
    }

    private func transcript(for record: SessionRecord) -> URL? {
        let projects = root.appending(path: "projects")
        // Claude Code names the folder after the cwd with every non-alphanumeric character as "-".
        let encoded = String(record.cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let direct = projects.appending(path: encoded).appending(path: "\(record.sessionId).jsonl")
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        let dirs = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        return dirs.lazy
            .map { $0.appending(path: "\(record.sessionId).jsonl") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func activity(of file: URL, bytes: Int = ClaudeCodeProvider.tailBytes) -> SessionActivity {
        guard let mtime = Self.mtime(file) else { return SessionActivity() }
        if let cached = tails[file.path], cached.mtime == mtime { return cached.activity }
        let activity = SessionLog.activity(fromTail: Self.tail(of: file, bytes: bytes))
        tails[file.path] = (mtime, activity)
        return activity
    }

    /// The session's latest subagents, newest first, with what each did so far, and how many
    /// older ones there are. Transcripts are read incrementally: only bytes added since the last
    /// scan (the first sight of one reads it once).
    private func subagents(of transcript: URL, now: Date) -> (shown: [AgentSubagent], earlier: Int) {
        let dir = transcript.deletingPathExtension().appending(path: "subagents")
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { file in Self.mtime(file).map { (file, $0) } }
            .sorted { $0.1 > $1.1 }
        let shown = files.prefix(Self.subagentsShown).map { file, mtime -> AgentSubagent in
            let id = file.deletingPathExtension().lastPathComponent
            let meta = subagentMeta(id: id, dir: dir)
            let progress = read(subagent: file)
            let status = progress.status(modified: mtime, now: now)
            return AgentSubagent(
                id: id, name: meta?.description ?? meta?.agentType ?? "Subagent",
                step: status == .running ? progress.steps.last?.text : nil,
                agentType: meta?.agentType, status: status, modified: mtime, progress: progress)
        }
        return (Array(shown), max(0, files.count - Self.subagentsShown))
    }

    private func subagentMeta(id: String, dir: URL) -> SubagentMeta? {
        if let meta = subagentMeta[id] { return meta }
        let meta = (try? Data(contentsOf: dir.appending(path: "\(id).meta.json"))).flatMap(SubagentMeta.decode)
        if let meta { subagentMeta[id] = meta }
        return meta
    }

    /// New lines since the last read; a partial last line waits for the next scan.
    private func read(subagent file: URL) -> SubagentProgress {
        var entry = subagentReads[file.path] ?? (0, SubagentProgress())
        guard let handle = try? FileHandle(forReadingFrom: file) else { return entry.progress }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < entry.offset { entry = (0, SubagentProgress()) }  // rewritten
        guard size > entry.offset else { return entry.progress }
        // First sight of a long transcript: its opening (the task) and its last 256 KB, not the
        // megabytes between; counts then cover that tail only.
        let window: UInt64 = 256 * 1024
        if entry.offset == 0, size > 2 * window {
            let head = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
            if let cut = head.lastIndex(of: 0x0A) {
                entry.progress.feed(lines: Substring(String(decoding: head[head.startIndex...cut], as: UTF8.self)))
            }
            try? handle.seek(toOffset: size - window)
            let tail = (try? handle.read(upToCount: Int(window))) ?? Data()
            if let first = tail.firstIndex(of: 0x0A), let last = tail.lastIndex(of: 0x0A), first < last {
                entry.progress.feed(lines: Substring(String(decoding: tail[tail.index(after: first)...last], as: UTF8.self)))
                entry.offset = size - window + UInt64(tail.distance(from: tail.startIndex, to: last) + 1)
            } else {
                entry.offset = size
            }
            entry.progress.partial = true
            subagentReads[file.path] = entry
            return entry.progress
        }
        try? handle.seek(toOffset: entry.offset)
        let data = (try? handle.read(upToCount: Int(size - entry.offset))) ?? Data()
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return entry.progress }
        let complete = data[data.startIndex...lastNewline]
        entry.progress.feed(lines: Substring(String(decoding: complete, as: UTF8.self)))
        entry.offset += UInt64(complete.count)
        subagentReads[file.path] = entry
        return entry.progress
    }

    /// The projects the Claude app groups sessions under: each session's working directory,
    /// resolved to its git top level (or an Obsidian notes folder), from live sessions and transcripts.
    /// The home folder and loose folders stay out.
    public nonisolated static func knownProjects(root: URL = defaultRoot) -> [String] {
        let fm = FileManager.default
        var paths = Set<String>()
        // Live sessions.
        let registry = root.appending(path: "sessions")
        for file in (try? fm.contentsOfDirectory(at: registry, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "json" {
            if let record = (try? Data(contentsOf: file)).flatMap(SessionRecord.decode), !record.isBackgroundHelper {
                paths.insert(record.cwd)
            }
        }
        // Transcripts: the first records carry the cwd, so read the head of the newest file.
        let projects = root.appending(path: "projects")
        for dir in (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        where !dir.lastPathComponent.contains("claude-mem") {
            let files = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { $0.pathExtension == "jsonl" }
                .sorted { (mtime($0) ?? .distantPast) > (mtime($1) ?? .distantPast) }
            for file in files.prefix(3) {
                if let cwd = head(of: file, bytes: 96 * 1024).firstMatch(of: #/"cwd":"([^"]+)"/#)?.output.1 {
                    paths.insert(String(cwd))
                    break
                }
            }
        }
        return ProjectPaths.projects(fromCwds: paths)
    }

    // MARK: Helpers

    public nonisolated static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    public nonisolated static func mtime(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    public nonisolated static func head(of url: URL, bytes: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        return String(decoding: (try? handle.read(upToCount: bytes)) ?? Data(), as: UTF8.self)
    }

    public nonisolated static func tail(of url: URL, bytes: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// Project names from working directories, shared by every provider so one project gets one
/// character whichever tool works in it.
public enum ProjectPaths {
    /// The git top level above a folder (worktrees included), or the folder itself when it is an
    /// Obsidian notes folder (`.obsidian`); `nil` for loose folders and the home folder.
    public static func projectRoot(of path: String) -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath().path
        var url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        while url.path != "/" && url.path != home {
            if fm.fileExists(atPath: url.path + "/.git") || fm.fileExists(atPath: url.path + "/.obsidian") { return url.path }
            url.deleteLastPathComponent()
        }
        return nil
    }

    /// Display name of a session's project, as the Claude app shows it.
    public static func projectName(ofCwd cwd: String) -> String {
        ProjectKey.project(cwd: projectRoot(of: cwd) ?? cwd)
    }

    /// Distinct project names for a set of working directories (worktrees fold into their repo).
    public static func projects(fromCwds paths: Set<String>) -> [String] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath().path
        var names = Set<String>()
        for path in paths {
            let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            var root = url.path
            for marker in ["/.claude/worktrees/", "/.worktrees/", "/.codex/worktrees/"] {
                if let range = root.range(of: marker) { root = String(root[..<range.lowerBound]) }
            }
            guard root != home, fm.fileExists(atPath: root), let project = projectRoot(of: root) else { continue }
            names.insert(ProjectKey.project(cwd: project))
        }
        return names.sorted()
    }
}
