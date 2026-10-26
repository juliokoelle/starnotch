import Foundation
import Testing
import TestSupport
@testable import NotchCore

@Suite struct RecentSessionsTests {
    @Test func newestFirstWithoutLiveOrOld() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "recent-sessions-\(UUID().uuidString.prefix(8))")
        defer { Fixtures.remove(root) }
        let dir = root.appending(path: "projects/-Users-me-code-app")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let now = Date()
        func write(_ id: String, prompt: String, age: TimeInterval) throws {
            let line = #"{"type":"user","cwd":"/Users/me/code/app","message":{"role":"user","content":"\#(prompt)"}}"#
            let url = dir.appending(path: "\(id).jsonl")
            try (line + "\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        try write("aaaaaaaa-0000-0000-0000-000000000001", prompt: "Fix the login bug", age: 3600)
        try write("aaaaaaaa-0000-0000-0000-000000000002", prompt: "Add dark mode", age: 60)
        try write("aaaaaaaa-0000-0000-0000-000000000003", prompt: "Still running", age: 30)
        try write("aaaaaaaa-0000-0000-0000-000000000004", prompt: "Old work", age: 10 * 86_400)
        let found = RecentSessions.scan(root: root, excluding: ["aaaaaaaa-0000-0000-0000-000000000003"], now: now)
        #expect(found.map(\.title) == ["Add dark mode", "Fix the login bug"])
        #expect(found.first?.cwd == "/Users/me/code/app")
    }

    @Test func resumeScriptQuotesTheFolder() throws {
        let session = RecentSession(id: "aaaaaaaa-0000-0000-0000-000000000001", title: "x", cwd: "/Users/me/it's here",
                                    project: "here", modified: Date())
        let script = try #require(RecentSessions.resumeScript(session))
        #expect(script.contains(#"cd '/Users/me/it'\''s here' || exit 1"#))
        #expect(script.hasSuffix("exec claude --resume aaaaaaaa-0000-0000-0000-000000000001\n"))
        var bad = session
        bad.id = "x; rm -rf ~"
        #expect(RecentSessions.resumeScript(bad) == nil)
    }
}
