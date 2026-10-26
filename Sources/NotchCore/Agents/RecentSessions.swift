import Foundation

/// A Claude Code session that ended in the last days, to pick up again.
public struct RecentSession: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var cwd: String
    public var project: String
    public var modified: Date

    public init(id: String, title: String, cwd: String, project: String, modified: Date) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.project = project
        self.modified = modified
    }
}

/// Past sessions from `~/.claude/projects/*/<id>.jsonl`, newest first, without the ones still
/// running. Each transcript's head and tail are read for its title and folder.
public enum RecentSessions {
    public static func scan(root: URL, excluding live: Set<String>, now: Date,
                            days: Double = 7, limit: Int = 6) -> [RecentSession] {
        let fm = FileManager.default
        var files: [(url: URL, id: String, mtime: Date)] = []
        let projects = root.appending(path: "projects")
        for dir in (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        where !dir.lastPathComponent.contains("claude-mem") {
            for file in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            where file.pathExtension == "jsonl" {
                let id = file.deletingPathExtension().lastPathComponent
                guard isSessionID(id), !live.contains(id), let mtime = ClaudeCodeProvider.mtime(file),
                      now.timeIntervalSince(mtime) < days * 86_400 else { continue }
                files.append((file, id, mtime))
            }
        }
        var found: [RecentSession] = []
        for file in files.sorted(by: { $0.mtime > $1.mtime }) {
            if found.count >= limit { break }
            let tail = SessionLog.activity(fromTail: ClaudeCodeProvider.tail(of: file.url, bytes: 64 * 1024))
            let head = SessionLog.activity(fromTail: ClaudeCodeProvider.head(of: file.url, bytes: 64 * 1024))
            guard let cwd = tail.cwd ?? head.cwd else { continue }
            let title = tail.title ?? head.firstPrompt ?? tail.firstPrompt
            guard let title else { continue }  // never got a prompt: nothing to resume
            found.append(RecentSession(id: file.id, title: title, cwd: cwd,
                                       project: ProjectPaths.projectName(ofCwd: cwd), modified: file.mtime))
        }
        return found
    }

    /// Claude Code's session ids are UUIDs; anything else is never put into a script.
    public static func isSessionID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    /// The script Terminal runs for "Resume": into the folder, then `claude --resume <id>`.
    public static func resumeScript(_ session: RecentSession) -> String? {
        guard isSessionID(session.id) else { return nil }
        let folder = "'" + session.cwd.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "#!/bin/zsh -l\ncd \(folder) || exit 1\nexec claude --resume \(session.id)\n"
    }
}
