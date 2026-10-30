import Darwin
import Foundation
import NotchCore
import SQLite3

/// Golden-test fixtures (Tests/Fixtures): anonymised copies of real tool files, laid out in a
/// temporary folder the way each tool keeps them.
public enum Fixtures {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures")

    /// A file of the repository itself (`CHANGELOG.md`).
    public static func repoFile(_ path: String) throws -> String {
        try String(contentsOf: root.deletingLastPathComponent().deletingLastPathComponent().appending(path: path), encoding: .utf8)
    }

    public static func text(_ path: String) -> String {
        (try? String(contentsOf: root.appending(path: path), encoding: .utf8)) ?? ""
    }

    public static func temp(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(name)-\(UUID().uuidString.prefix(8))")
        // Setup failures stop the run here, so a broken temp folder is not reported later as a missing session.
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func place(_ fixture: String, at url: URL, modified: Date) {
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        try! FileManager.default.copyItem(at: root.appending(path: fixture), to: url)
        try! FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    /// A Codex folder with the thread database and four paginated rollouts (one done, one
    /// working with a running subagent, and the automatic reviewer), as of `now`.
    public static func codexHome(now: Date) -> URL {
        let home = temp("codex")
        let day = home.appending(path: "sessions/2026/10/20")
        let rollouts: [(String, String, Double)] = [
            ("codex/paginated-done.jsonl", "rollout-2026-10-20T11-52-48-019a0001-0000-7000-8000-00000000c0de.jsonl", 600),
            ("codex/paginated-working.jsonl", "rollout-2026-10-20T11-55-00-019a0001-0000-7000-8000-00000000b0d1.jsonl", 30),
            ("codex/subagent.jsonl", "rollout-2026-10-20T11-56-00-019a0001-0000-7000-8000-00000000b0d2.jsonl", 20),
            ("codex/guardian.jsonl", "rollout-2026-10-20T11-53-03-019a0001-0000-7000-8000-00000000a0d1.jsonl", 650),
        ]
        for (fixture, name, age) in rollouts {
            place(fixture, at: day.appending(path: name), modified: now.addingTimeInterval(-age))
        }
        let sql = text("codex/threads.sql")
            .replacingOccurrences(of: "{ROOT}", with: home.path)
            .replacingOccurrences(of: "{NOW}", with: String(Int(now.timeIntervalSince1970)))
        var db: OpaquePointer?
        let opened = sqlite3_open(home.appending(path: "state_5.sqlite").path, &db)
        precondition(opened == SQLITE_OK, "Codex fixture database could not be opened (\(opened))")
        let filled = sqlite3_exec(db, sql, nil, nil, nil)
        precondition(filled == SQLITE_OK, "Codex fixture database could not be filled (\(filled))")
        sqlite3_close(db)
        return home
    }

    /// A Codex folder without a database, holding one rollout in the older format (from today).
    public static func codexLegacyHome(now: Date, fixture: String = "codex/legacy.jsonl") -> URL {
        let home = temp("codex-legacy")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        let day = home.appending(path: String(format: "sessions/%04d/%02d/%02d", parts.year!, parts.month!, parts.day!))
        place(fixture, at: day.appending(path: "rollout-2025-09-18T08-00-00-0199a000-0000-7000-8000-00000000eeee.jsonl"),
              modified: now.addingTimeInterval(-60))
        return home
    }

    /// A Claude Code folder with one live session (this test process stands in for it) and the
    /// Claude app's desktop session files.
    public static func claudeHome() -> (home: URL, desktop: URL) {
        let base = temp("claude")
        let home = base.appending(path: "home"), desktop = base.appending(path: "desktop")
        try! FileManager.default.copyItem(at: root.appending(path: "claude/home"), to: home)
        try! FileManager.default.copyItem(at: root.appending(path: "claude/desktop"), to: desktop)
        let pid = getpid()
        let template = home.appending(path: "sessions/PID.json")
        let record = (try? String(contentsOf: template, encoding: .utf8))?.replacingOccurrences(of: "{PID}", with: String(pid)) ?? ""
        try? FileManager.default.removeItem(at: template)
        try? record.write(to: home.appending(path: "sessions/\(pid).json"), atomically: true, encoding: .utf8)
        return (home, desktop)
    }

    public static func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }
}

/// A temporary home for the setup tests: never the real ~/.claude or ~/.codex.
public enum SetupSandbox {
    public static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// A home with an existing Claude settings file and status line, a Codex folder, a .zshrc,
    /// and a fake `claude` that logs its arguments (and fails the GitHub marketplace when asked).
    public static func make(failGitHub: Bool = false) -> SetupPaths {
        let home = Fixtures.temp("setup-home")
        let fm = FileManager.default
        try? fm.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: home.appending(path: ".codex"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: home.appending(path: ".local/bin"), withIntermediateDirectories: true)
        try? #"{"model":"opus","statusLine":{"type":"command","command":"bash ~/.claude/my status.sh","padding":0},"theme":"dark"}"#
            .write(to: home.appending(path: ".claude/settings.json"), atomically: true, encoding: .utf8)
        try? #"{"hooks":{}}"#.write(to: home.appending(path: ".codex/hooks.json"), atomically: true, encoding: .utf8)
        try? "export PATH=$HOME/bin:$PATH\n".write(to: home.appending(path: ".zshrc"), atomically: true, encoding: .utf8)
        let fake = """
        #!/bin/bash
        echo "$*" >> "$HOME/claude-calls.log"
        if [ "\(failGitHub ? "1" : "0")" = "1" ] && [ "$4" = "juliokoelle/starnotch" ]; then echo "network error" >&2; exit 1; fi
        exit 0
        """
        let claude = home.appending(path: ".local/bin/claude")
        try? fake.write(to: claude, atomically: true, encoding: .utf8)
        chmod(claude.path, 0o755)
        return SetupPaths(home: home, support: home.appending(path: "Library/Application Support/Starnotch"),
                          integrations: repo.appending(path: "integrations"),
                          bridgeScript: repo.appending(path: "scripts/statusline-bridge.sh"))
    }

    public static func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    public static func json(_ url: URL) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
    }

    public static func statusCommand(_ paths: SetupPaths) -> String? {
        (json(paths.claudeSettings)["statusLine"] as? [String: Any])?["command"] as? String
    }

    public static func value(_ paths: SetupPaths, _ key: String) -> String? {
        json(paths.claudeSettings)[key] as? String
    }

    public static func hasCodexHook(_ paths: SetupPaths) -> Bool {
        read(paths.codexHome.appending(path: "hooks.json")).contains("starnotch-ask-notch.sh")
    }

    public static func exists(_ path: String?) -> Bool { path.map { FileManager.default.fileExists(atPath: $0) } ?? false }
}
