import Foundation

/// opencode: its session table (`~/.local/share/opencode/opencode.db`, read-only) for titles and
/// folders, and Starnotch's plugin (`~/.config/opencode/plugins/starnotch.js`, set up on the consent
/// page) for live status and permission prompts the island can answer (once, always, reject).
public actor OpencodeProvider: AgentProvider, HookSessionSource {
    public static let id = "opencode"
    public static let displayName = "opencode"

    public static var dataFolder: URL {
        let env = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        return (env ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/share")).appending(path: "opencode")
    }

    public static func detect() -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: dataFolder.path)
            || ["/opt/homebrew/bin/opencode", "/usr/local/bin/opencode",
                fm.homeDirectoryForCurrentUser.appending(path: ".opencode/bin/opencode").path].contains { fm.isExecutableFile(atPath: $0) }
    }

    static let recentWindow: TimeInterval = 30 * 60
    static let maxSessions = 6

    public nonisolated let folder: URL
    private var tool: HookedTool
    private var rows: [OpencodeSessionRow] = []
    private var rowsStamp: Date?

    public init(folder: URL = OpencodeProvider.dataFolder, useProcesses: Bool = true) {
        self.folder = folder
        tool = HookedTool(names: ["opencode"], useProcesses: useProcesses)
    }

    public nonisolated var watchPaths: [URL] { [folder] }

    public func ingest(_ update: HookUpdate) { tool.hooks.apply(update) }

    public func scan(now: Date) async -> ProviderScan {
        ProviderScan(sessions: tool.sessions(provider: Self.id, now: now, files: fileSessions(now: now)))
    }

    func fileSessions(now: Date) -> [AgentSession] {
        let database = folder.appending(path: "opencode.db")
        let stamp = [database, folder.appending(path: "opencode.db-wal")].compactMap(ClaudeCodeProvider.mtime).max()
        if stamp != rowsStamp {
            rows = OpencodeSessionRow.recent(database: database.path, since: now.addingTimeInterval(-Self.recentWindow)) ?? []
            rowsStamp = stamp
        }
        let recent = rows.filter { now.timeIntervalSince($0.updated) < Self.recentWindow }
        let children = Dictionary(grouping: recent.filter { $0.parentID != nil }) { $0.parentID! }
        return recent.filter { $0.parentID == nil }.prefix(Self.maxSessions).map { row in
            let subs = (children[row.id] ?? []).sorted { $0.updated > $1.updated }
            return AgentSession(
                id: "\(Self.id):\(row.id)", project: ProjectPaths.projectName(ofCwd: row.directory),
                title: row.title, cwd: row.directory, isBusy: false, since: row.updated,
                subagents: subs.prefix(5).map { AgentSubagent(id: "\(Self.id):\($0.id)", name: $0.title ?? "Subagent",
                                                              agentType: Self.id, status: .done, modified: $0.updated) },
                earlierSubagents: max(0, subs.count - 5), started: row.created, provider: Self.id)
        }
    }
}

/// One row of opencode's `session` table.
public struct OpencodeSessionRow: Equatable, Sendable {
    public var id: String
    public var parentID: String?
    public var directory: String
    public var title: String?
    public var created: Date?
    public var updated: Date

    /// Sessions changed since `since`, newest first; nil when the database or its columns are missing.
    public static func recent(database: String, since: Date) -> [OpencodeSessionRow]? {
        guard let db = SQLiteReader(path: database) else { return nil }
        let columns = db.columns(of: "session")
        guard ["id", "directory", "time_updated"].allSatisfy(columns.contains) else { return nil }
        let wanted = ["id", "parent_id", "directory", "title", "time_created", "time_updated"].filter(columns.contains)
        var sql = "SELECT \(wanted.joined(separator: ", ")) FROM session WHERE time_updated >= ?"
        if columns.contains("time_archived") { sql += " AND time_archived IS NULL" }
        sql += " ORDER BY time_updated DESC LIMIT 30"
        // opencode stores milliseconds.
        return db.rows(sql, [String(Int(since.timeIntervalSince1970 * 1000))]).compactMap { row in
            func text(_ key: String) -> String? { (row[key] ?? nil)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
            func date(_ key: String) -> Date? { text(key).flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) } }
            guard let id = text("id"), let directory = text("directory"), let updated = date("time_updated") else { return nil }
            return OpencodeSessionRow(id: id, parentID: text("parent_id"), directory: directory,
                                      title: text("title").map(HookUpdate.short), created: date("time_created"), updated: updated)
        }
    }
}
