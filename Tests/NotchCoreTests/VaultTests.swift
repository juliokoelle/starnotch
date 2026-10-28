import Foundation
import Testing
import TestSupport
@testable import NotchCore

@Suite struct VaultTests {
    @Test func readsOpenTasksWithDueDatesTagsAndSections() {
        let text = """
        ---
        title: Tasks
        - [ ] not a task, front matter
        ---
        # Tasks
        ## Work
        - [ ] Send the deck 📅 2026-10-28 #work
        * [ ] **Call Ada.** About the review [due:: 2026-10-27 9:30]
          - bring the notes
          - [[people/Ada Lovelace|Ada]] knows
        - [x] Done already 📅 2026-10-20
        1. [ ] Numbered (due 2026-10-30) @home
        ```
        - [ ] inside a code block
        ```
        ## Later
        - [ ] Read [the book](https://example.com/#a) 🔁 every week ⏫
        -[ ] no space is no task
        """
        let tasks = MarkdownTasks.parse(text, file: "Tasks.md")
        #expect(tasks.map(\.title) == ["Send the deck", "Call Ada", "Numbered", "Read the book"])
        #expect(tasks.map(\.due) == ["2026-10-28", "2026-10-27", "2026-10-30", nil])
        #expect(tasks[1].time == "09:30")
        #expect(tasks[1].detail == "About the review")
        #expect(tasks[1].notes == ["bring the notes", "Ada knows"])
        #expect(tasks[0].tags == ["work"] && tasks[2].tags == ["home"])
        #expect(tasks.map(\.section) == ["Work", "Work", "Work", "Later"])
        #expect(tasks[3].repeats && !tasks[0].repeats)
        #expect(tasks[0].line == 6)
    }

    @Test func idsStayWhenLinesMove() {
        let before = MarkdownTasks.parse("- [ ] A\n- [ ] B\n", file: "t.md")
        let after = MarkdownTasks.parse("# New heading\n\n- [ ] A\n- [ ] B\n", file: "t.md")
        #expect(before.map(\.id) == after.map(\.id))
        let twins = MarkdownTasks.parse("- [ ] Same\n- [ ] Same\n", file: "t.md")
        #expect(Set(twins.map(\.id)).count == 2)
    }

    @Test func tickingOffChangesOnlyThatLine() throws {
        let text = "# T\r\n- [ ] Keep\r\n- [ ] Tick me 📅 2026-10-28\r\n- [ ] Keep too\r\n"
        let task = try #require(MarkdownTasks.parse(text, file: "t.md").first { $0.title == "Tick me" })
        let done = try #require(MarkdownTasks.completing(task, in: text))
        #expect(done == "# T\r\n- [ ] Keep\r\n- [x] Tick me 📅 2026-10-28\r\n- [ ] Keep too\r\n")
    }

    @Test func tickingOffFindsAMovedLineButNeverGuesses() throws {
        let text = "- [ ] Alpha\n- [ ] Beta\n"
        let beta = try #require(MarkdownTasks.parse(text, file: "t.md").last)
        // Lines added above: found again by its exact text.
        #expect(MarkdownTasks.completing(beta, in: "- [ ] New\n" + text) == "- [ ] New\n- [ ] Alpha\n- [x] Beta\n")
        // Edited meanwhile, gone, or there twice at other places: nothing is written.
        #expect(MarkdownTasks.completing(beta, in: "- [ ] Alpha\n- [ ] Beta, edited\n") == nil)
        #expect(MarkdownTasks.completing(beta, in: "- [ ] Alpha\n") == nil)
        #expect(MarkdownTasks.completing(beta, in: "- [ ] X\n- [ ] Y\n- [ ] Beta\n- [ ] Beta\n") == nil)
        // Ticked off elsewhere already.
        #expect(MarkdownTasks.completing(beta, in: "- [ ] Alpha\n- [x] Beta\n") == nil)
    }

    @Test func dailyNotePathsKeepFolderNames() {
        let date = UTC.date("2026-03-07 12:00")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        #expect(DailyNote.path(pattern: "10_Daily/YYYY-MM-DD.md", date: date, calendar: calendar) == "10_Daily/2026-03-07.md")
        #expect(DailyNote.path(pattern: "Daily Notes/YYYY/MM/YYYY-MM-DD.md", date: date, calendar: calendar) == "Daily Notes/2026/03/2026-03-07.md")
        #expect(DailyNote.path(pattern: "Days/D.M.YY.md", date: date, calendar: calendar) == "Days/7.3.26.md")
        #expect(DailyNote.path(pattern: "[Day] YYYY-MM-DD.md", date: date, calendar: calendar) == "Day 2026-03-07.md")
    }

    @Test func headingsOfTheDailyNote() {
        let note = "---\ndate: 2026-10-28\n---\n# 2026-10-28\n\n## ☀️ Morning\n[[brief]]\n## Notes\n```\n## not a heading\n```\n### **Log**\n"
        #expect(DailyNote.headings(note) == ["☀️ Morning", "Notes", "Log"])
        #expect(DailyNote.headings("# Only a title\ntext") == ["Only a title"])
        #expect(DailyNote.body("---\na: 1\n---\nHello world", limit: 5) == "Hello…")
    }

    @Test func detectsTheFilesInAFolder() throws {
        let root = try Self.folder([
            "Inbox.md": "- [ ] one\n",
            "Areas/Tasks.md": "- [ ] two\n",
            "System/loops/RUNLOG.md": "2026-10-28 · brief · ok · fine\n",
            "Journal/2026-10-27.md": "", "Journal/2026-10-28.md": "", "Other/2026-01-01.md": "",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = VaultDetect.detect(in: root)
        #expect(layout == VaultLayout(tasks: "Areas/Tasks.md", daily: "Journal/YYYY-MM-DD.md", inbox: "Inbox.md", loops: "System/loops/RUNLOG.md"))

        // Obsidian's own daily notes settings win over guessing.
        try FileManager.default.createDirectory(at: root.appending(path: ".obsidian"), withIntermediateDirectories: true)
        try Data(#"{"folder":"Days/","format":"YYYY/MM-DD"}"#.utf8).write(to: root.appending(path: ".obsidian/daily-notes.json"))
        #expect(VaultDetect.detect(in: root).daily == "Days/YYYY/MM-DD.md")
    }

    @Test func todayTicksOffAndWritesTheSnapshot() throws {
        let now = Date()
        let day = { (offset: Double) in RunLog.day(now.addingTimeInterval(offset * 86_400)) }
        let tasks = """
        ## Now
        - [ ] Late 📅 \(day(-2))
        - [ ] Today [due:: \(day(0))]
        - [ ] Soon 📅 \(day(3))
        - [ ] Someday
        """
        let root = try Self.folder(["Tasks.md": tasks, "Daily/\(day(0)).md": "# \(day(0))\n## Plan\n## Log\n", "Inbox.md": "- [ ] idea\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshotURL = root.appending(path: "out/vault.json")
        let vault = VaultConnector(config: ConfigSection(values: [
            "folder": .string(root.path), "tasks": .string("Tasks.md"), "daily": .string("Daily/YYYY-MM-DD.md"), "inbox": .string("Inbox.md"),
        ]), defaults: UserDefaults(suiteName: "app.starnotch.tests")!, snapshotURL: snapshotURL)

        let feed = vault.today(now: now)
        #expect(feed.now.map(\.title) == ["Late", "Today"])
        #expect(feed.followUps.map(\.title) == ["Soon"])
        #expect(feed.brief?.text == "Plan · Log")
        #expect(feed.counters.map(\.value) == [4, 1])

        // Ticking off writes "- [x]" into that line only.
        let late = try #require(feed.now.first)
        #expect(vault.canComplete(late.id))
        #expect(vault.complete(late.id))
        let written = try String(contentsOf: root.appending(path: "Tasks.md"), encoding: .utf8)
        #expect(written == tasks.replacingOccurrences(of: "- [ ] Late", with: "- [x] Late"))
        #expect(vault.today(now: now).now.map(\.title) == ["Today"])

        // Edited elsewhere after it was read: not written.
        let today = try #require(vault.today(now: now).now.first)
        try Data(written.replacingOccurrences(of: "- [ ] Today", with: "- [ ] Today, moved").utf8).write(to: root.appending(path: "Tasks.md"))
        #expect(!vault.complete(today.id))
        #expect(try String(contentsOf: root.appending(path: "Tasks.md"), encoding: .utf8).contains("- [ ] Today, moved"))

        // The snapshot for Tara.
        #expect(vault.writeSnapshot(now: now))
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: snapshotURL)) as? [String: Any]
        #expect(json?["open_tasks"] as? Int == 3)
        #expect((json?["daily_note"] as? [String: Any])?["headings"] as? [String] == ["Plan", "Log"])
        #expect((json?["recent_notes"] as? [Any])?.count == 3)
    }

    @Test func unconfiguredIsNotSetUp() {
        let vault = VaultConnector(config: ConfigSection(values: ["folder": .string("/no/such/folder")]),
                                   defaults: UserDefaults(suiteName: "app.starnotch.tests")!, snapshotURL: nil)
        #expect(!vault.isConfigured && vault.inboxFile == nil && vault.openTasks().isEmpty)
    }

    /// A temporary folder with these files.
    static func folder(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "vault-\(UUID().uuidString.prefix(8))")
        for (path, text) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        return root
    }
}
