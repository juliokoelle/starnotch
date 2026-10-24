import Foundation

/// The Claude app's Code sessions: one `local_<id>.json` per session under
/// `~/Library/Application Support/Claude/claude-code-sessions/<account>/<org>/`. Each names the
/// Claude Code session it runs (`cliSessionId`), so it only enriches that session: the title the
/// app shows, model and effort, and its post-turn summary ("needs action"). Read-only, cached by
/// modification time. `plan-usage-history.json` next to it is undocumented and stays unused.
public final class ClaudeDesktop: @unchecked Sendable {
    public struct Session: Equatable, Sendable {
        public var cliSessionId: String
        public var title: String?
        public var model: String?
        public var effort: String?
        public var lastActivityAt: Date?
        public var isArchived: Bool
        /// `postTurnSummary.status_category`: "blocked", "completed" …
        public var status: String?
        /// What the user has to do, when the app says so.
        public var needsAction: String?

        /// Decodes one session file; nil for anything that isn't one.
        public static func parse(_ data: Data) -> Session? {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cli = object["cliSessionId"] as? String, !cli.isEmpty else { return nil }
            func string(_ value: Any?) -> String? {
                (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            }
            let summary = object["postTurnSummary"] as? [String: Any]
            return Session(
                cliSessionId: cli,
                title: string(object["title"]),
                model: string(object["model"]),
                effort: string(object["effort"]),
                lastActivityAt: (object["lastActivityAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) },
                isArchived: object["isArchived"] as? Bool ?? false,
                status: string(summary?["status_category"]),
                needsAction: string(summary?["needs_action"]))
        }

        /// The app's view on top of what the files say: its title (unless the user named the
        /// session in the terminal), model and effort where the transcript has none, and the
        /// "needs action" line while the session rests.
        public func enrich(_ session: AgentSession, userNamed: Bool) -> AgentSession {
            var merged = session
            if !userNamed, let title { merged.title = title }
            if merged.model == nil { merged.model = model }
            if merged.effort == nil, let effort {
                merged.effort = effort
                merged.level = PerformanceLevel(effort: effort)
            }
            if !session.isBusy, status == "blocked", let needsAction { merged.needsYou = needsAction }
            return merged
        }
    }

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Claude/claude-code-sessions")
    }

    public let root: URL
    private let lock = NSLock()
    private var cache: [String: (mtime: Date, session: Session?)] = [:]

    /// Nil when the Claude app has no Code sessions folder.
    public init?(root: URL = ClaudeDesktop.defaultRoot) {
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        self.root = root
    }

    /// Sessions by their Claude Code session id; archived ones left out.
    public func sessions() -> [String: Session] {
        lock.lock()
        defer { lock.unlock() }
        var result: [String: Session] = [:]
        var seen = Set<String>()
        let fm = FileManager.default
        for account in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for org in (try? fm.contentsOfDirectory(at: account, includingPropertiesForKeys: nil)) ?? [] {
                for file in (try? fm.contentsOfDirectory(at: org, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
                    seen.insert(file.path)
                    guard let mtime = ClaudeCodeProvider.mtime(file) else { continue }
                    let session: Session?
                    if let cached = cache[file.path], cached.mtime == mtime {
                        session = cached.session
                    } else {
                        session = (try? Data(contentsOf: file)).flatMap(Session.parse)
                        cache[file.path] = (mtime, session)
                    }
                    if let session, !session.isArchived { result[session.cliSessionId] = session }
                }
            }
        }
        cache = cache.filter { seen.contains($0.key) }
        return result
    }
}
