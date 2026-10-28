import Foundation

/// Gemini CLI: its chat recordings (`~/.gemini/tmp/<project>/chats/session-*.jsonl`) and, once
/// set up, its hooks in `~/.gemini/settings.json`. Gemini's hooks can deny but never allow, so a
/// permission prompt shows as "waits for you" with a jump to its terminal, not as a card to answer.
/// No plan limits: Gemini keeps them on its server.
public actor GeminiProvider: AgentProvider, HookSessionSource {
    public static let id = "gemini"
    public static let displayName = "Gemini CLI"

    public static var defaultRoot: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: ".gemini") }

    public static func detect() -> Bool {
        FileManager.default.fileExists(atPath: defaultRoot.appending(path: "tmp").path)
            || FileManager.default.fileExists(atPath: defaultRoot.appending(path: "settings.json").path)
    }

    static let candidateWindow: TimeInterval = 6 * 3600
    static let recentWindow: TimeInterval = 30 * 60
    /// Gemini writes its answer when it is complete: a prompt without one for this long is over.
    static let staleBusy: TimeInterval = 5 * 60
    static let maxSessions = 6

    public nonisolated let root: URL
    private var tool: HookedTool
    private var cache: [String: (mtime: Date, chat: GeminiChat)] = [:]

    public init(root: URL = GeminiProvider.defaultRoot, useProcesses: Bool = true) {
        self.root = root
        tool = HookedTool(names: ["gemini"], scripts: ["gemini-cli", "/bin/gemini"], useProcesses: useProcesses)
    }

    public nonisolated var watchPaths: [URL] { [root.appending(path: "tmp")] }

    public func ingest(_ update: HookUpdate) { tool.hooks.apply(update) }

    public func scan(now: Date) async -> ProviderScan {
        ProviderScan(sessions: tool.sessions(provider: Self.id, now: now, files: fileSessions(now: now)))
    }

    func fileSessions(now: Date) -> [AgentSession] {
        let fm = FileManager.default
        let projects = (try? fm.contentsOfDirectory(at: root.appending(path: "tmp"), includingPropertiesForKeys: nil)) ?? []
        var found: [(GeminiChat, Date, String?)] = []
        for project in projects {
            let chats = project.appending(path: "chats")
            guard let mtime = ClaudeCodeProvider.mtime(chats), now.timeIntervalSince(mtime) < Self.candidateWindow else { continue }
            // Older versions keep the folder in a file next to the chats.
            let rootFile = (try? String(contentsOf: project.appending(path: ".project_root"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            for file in (try? fm.contentsOfDirectory(at: chats, includingPropertiesForKeys: nil)) ?? []
            where file.lastPathComponent.hasPrefix("session-") && file.pathExtension == "jsonl" {
                guard let fileTime = ClaudeCodeProvider.mtime(file), now.timeIntervalSince(fileTime) < Self.candidateWindow else { continue }
                if let cached = cache[file.path], cached.mtime == fileTime {
                    found.append((cached.chat, fileTime, rootFile))
                    continue
                }
                var chat = GeminiChat()
                chat.feed(lines: Substring(ClaudeCodeProvider.head(of: file, bytes: 16 * 1024)), headOnly: true)
                chat.feed(lines: Substring(ClaudeCodeProvider.tail(of: file, bytes: 128 * 1024)))
                cache[file.path] = (fileTime, chat)
                found.append((chat, fileTime, rootFile))
            }
        }
        return found.sorted { $0.1 > $1.1 }.compactMap { chat, mtime, rootFile -> AgentSession? in
            guard let id = chat.sessionID, let cwd = chat.directories.first ?? rootFile else { return nil }
            let busy = chat.awaitsAnswer && now.timeIntervalSince(mtime) < Self.staleBusy
            guard busy || now.timeIntervalSince(mtime) < Self.recentWindow else { return nil }
            return AgentSession(id: "\(Self.id):\(id)", project: ProjectPaths.projectName(ofCwd: cwd),
                                title: chat.summary ?? chat.firstPrompt, cwd: cwd, isBusy: busy,
                                since: chat.lastDate ?? mtime, steps: chat.steps, started: chat.started,
                                lastMessage: chat.lastMessage, model: chat.model, contextTokens: chat.contextTokens,
                                provider: Self.id)
        }.prefix(Self.maxSessions).map { $0 }
    }
}

/// One Gemini CLI chat recording (JSONL): a metadata record (`sessionId`, `startTime`,
/// `directories`), message records (`type` user, gemini, info …; `toolCalls`, `tokens`, `model`)
/// and `$set` updates (`summary`, `lastUpdated`).
public struct GeminiChat: Equatable, Sendable {
    public var sessionID: String?
    public var directories: [String] = []
    public var summary: String?
    public var started: Date?
    public var firstPrompt: String?
    public var lastMessage: String?
    public var model: String?
    public var contextTokens: Int?
    public var lastDate: Date?
    /// The last record is the user's: Gemini hasn't answered yet.
    public var awaitsAnswer = false
    public var steps: [SessionStep] = []

    public init() {}

    /// `headOnly`: the start of the file, read for the metadata record only.
    public mutating func feed(lines: Substring, headOnly: Bool = false) {
        for line in lines.split(whereSeparator: \.isNewline) {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            if let id = object["sessionId"] as? String, object["type"] == nil {
                sessionID = id
                directories = object["directories"] as? [String] ?? directories
                started = (object["startTime"] as? String).flatMap(SessionLog.parseDate) ?? started
                if let text = (object["summary"] as? String)?.nilIfEmpty { summary = HookUpdate.short(text) }
                continue
            }
            if headOnly { continue }
            if let set = object["$set"] as? [String: Any] {
                if let text = (set["summary"] as? String)?.nilIfEmpty { summary = HookUpdate.short(text) }
                continue
            }
            guard let type = object["type"] as? String else { continue }
            let at = (object["timestamp"] as? String).flatMap(SessionLog.parseDate)
            let text = Self.text(object["content"])
            switch type {
            case "user":
                if firstPrompt == nil, let text, !text.hasPrefix("/") { firstPrompt = HookUpdate.short(text) }
                awaitsAnswer = true
                lastDate = at ?? lastDate
            case "gemini":
                if let text, !text.isEmpty { lastMessage = HookUpdate.short(text) }
                model = (object["model"] as? String) ?? model
                if let tokens = object["tokens"] as? [String: Any], let input = (tokens["input"] as? NSNumber)?.intValue {
                    contextTokens = input
                }
                let calls = object["toolCalls"] as? [[String: Any]] ?? []
                for call in calls {
                    guard let name = call["name"] as? String else { continue }
                    var step = HookUpdate.step(tool: name, input: call["args"] as? [String: Any])
                    step.date = at
                    steps.append(step)
                }
                if steps.count > 8 { steps.removeFirst(steps.count - 8) }
                // Tool calls are recorded as they run; the answer without them ends the turn.
                awaitsAnswer = !calls.isEmpty && (text ?? "").isEmpty
                lastDate = at ?? lastDate
            default:
                break
            }
        }
    }

    /// A message's text: a string, or the text parts of a list.
    static func text(_ content: Any?) -> String? {
        if let string = content as? String { return string.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let parts = content as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
}
