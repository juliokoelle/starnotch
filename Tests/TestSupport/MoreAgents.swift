import Darwin
import Foundation
import NotchCore
import SQLite3

/// Helpers for the Cursor, Copilot CLI, Gemini CLI and opencode tests (the test files can't
/// import Foundation themselves).
public enum HookJSON {
    public static func update(_ json: String, at date: Date) -> HookUpdate? { HookUpdate.parse(Data(json.utf8), now: date) }

    public static func approval(_ json: String) -> ApprovalRequest? { ApprovalRequest.parse(Data(json.utf8), id: "t") }

    /// A fixture with the fields the hook script adds in front.
    public static func forwarded(_ fixture: String, provider: String, event: String, pid: Int = 4242) -> String {
        let body = Fixtures.text(fixture).trimmingCharacters(in: .whitespacesAndNewlines)
        return "{\"starnotch_provider\":\"\(provider)\",\"starnotch_event\":\"\(event)\",\"starnotch_pid\":\(pid),\"starnotch_tty\":\"/dev/ttys007\"," + body.dropFirst()
    }

    public static func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }
}

extension Fixtures {
    /// A Copilot CLI folder with two session folders: one working (written 30 s ago), one done.
    public static func copilotHome(now: Date) -> URL {
        let home = temp("copilot")
        try? FileManager.default.copyItem(at: root.appending(path: "copilot/session-state"), to: home.appending(path: "session-state"))
        for (id, age) in [("5a1f0c2e-0000-4000-8000-00000000c011", 30.0), ("5a1f0c2e-0000-4000-8000-00000000c012", 480.0)] {
            try? FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)],
                                                   ofItemAtPath: home.appending(path: "session-state/\(id)/events.jsonl").path)
        }
        return home
    }

    /// A Gemini CLI folder with one chat whose last record is a prompt (written 30 s ago).
    public static func geminiHome(now: Date, age: Double = 30) -> URL {
        let home = temp("gemini")
        try? FileManager.default.copyItem(at: root.appending(path: "gemini/tmp"), to: home.appending(path: "tmp"))
        let chat = home.appending(path: "tmp/harbor/chats/session-2026-10-20T11-50-ab12cd34.jsonl")
        try? FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: chat.path)
        try? FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: chat.deletingLastPathComponent().path)
        return home
    }

    /// An opencode data folder with its session table, as of `now`.
    public static func opencodeFolder(now: Date) -> URL {
        let folder = temp("opencode")
        let sql = text("opencode/sessions.sql").replacingOccurrences(of: "{NOW_MS}", with: String(Int(now.timeIntervalSince1970 * 1000)))
        var db: OpaquePointer?
        sqlite3_open(folder.appending(path: "opencode.db").path, &db)
        sqlite3_exec(db, sql, nil, nil, nil)
        sqlite3_close(db)
        return folder
    }
}

extension SetupSandbox {
    /// A sandbox home that also has Cursor, Copilot CLI and Gemini CLI folders, with existing
    /// settings of the user's own in Cursor and Gemini.
    public static func makeWithMoreAgents() -> SetupPaths {
        let paths = make()
        let fm = FileManager.default
        for folder in [paths.cursorHome, paths.copilotHome, paths.geminiHome] {
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try? #"{"version":1,"hooks":{"stop":[{"command":"./hooks/my-audit.sh"}]}}"#
            .write(to: paths.cursorHome.appending(path: "hooks.json"), atomically: true, encoding: .utf8)
        try? #"{"theme":"GitHub","hooks":{"BeforeTool":[{"matcher":"run_shell_command","hooks":[{"type":"command","command":"~/guard.sh"}]}]}}"#
            .write(to: paths.geminiHome.appending(path: "settings.json"), atomically: true, encoding: .utf8)
        return paths
    }

    public static func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }
    public static func write(_ text: String, to url: URL) { try? text.write(to: url, atomically: true, encoding: .utf8) }
}
