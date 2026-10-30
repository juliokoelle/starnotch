import Foundation
import Testing
import TestSupport
@testable import NotchCore

/// Tara's memory: pause, sources, the ignore list, deleting per source, today's calendar.
@Suite struct MemoryPrivacyTests {
    let now = UTC.date("2026-10-28 20:00")

    @Test func everythingRecordsByDefaultButTheOptInSources() {
        let privacy = MemoryPrivacy()
        for source in MemorySource.allCases where !source.isOptIn {
            #expect(privacy.records(source, at: now))
            #expect(privacy.shares(source))
        }
        // Time per app waits for the user to turn it on.
        #expect(!privacy.records(.apps, at: now) && !privacy.shares(.apps))
        #expect(!privacy.records(.screen, at: now))
        #expect(!privacy.shares(.screen))
        #expect(privacy.switchedOff == [.apps, .screen])
        #expect(!privacy.isPaused(at: now))
    }


    @Test func aPauseStopsRecordingButNotSharing() {
        var privacy = MemoryPrivacy()
        privacy.pause(.oneHour, now: now)
        #expect(privacy.isPaused(at: now.addingTimeInterval(59 * 60)))
        #expect(!privacy.records(.meetings, at: now.addingTimeInterval(60)))
        #expect(privacy.shares(.meetings))
        // Over after the hour.
        #expect(!privacy.isPaused(at: now.addingTimeInterval(3601)))
        #expect(privacy.records(.meetings, at: now.addingTimeInterval(3601)))
        privacy.expire(at: now.addingTimeInterval(3601))
        #expect(privacy.pausedUntil == nil)
    }

    @Test func pauseLengths() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        #expect(MemoryPause.untilTomorrow.end(from: now, calendar: calendar) == UTC.date("2026-10-29 00:00"))
        var privacy = MemoryPrivacy()
        privacy.pause(.untilResumed, now: now)
        #expect(privacy.isPausedUntilResumed)
        #expect(privacy.isPaused(at: now.addingTimeInterval(365 * 86_400)))
        privacy.resume()
        #expect(!privacy.isPaused(at: now))
    }

    @Test func aSourceThatIsOffNeitherRecordsNorShares() {
        var privacy = MemoryPrivacy()
        privacy.set(.clipboard, on: false)
        privacy.set(.meetings, on: false)
        privacy.set(.clipboard, on: false)
        #expect(privacy.off == [.meetings, .clipboard])
        #expect(!privacy.records(.clipboard, at: now))
        #expect(!privacy.shares(.meetings))
        #expect(privacy.records(.captures, at: now))
        privacy.set(.meetings, on: true)
        #expect(privacy.off == [.clipboard])
    }

    @Test func ignoredAppsNeverRecordAndPasswordAppsAlwaysCount() {
        var privacy = MemoryPrivacy()
        #expect(privacy.ignores(app: "com.1password.1password"))
        #expect(!privacy.records(.clipboard, at: now, app: "com.bitwarden.desktop"))
        #expect(privacy.records(.clipboard, at: now, app: "com.apple.Notes"))
        privacy.ignore(IgnoredApp(bundleID: "com.apple.Notes", name: "Notes"))
        privacy.ignore(IgnoredApp(bundleID: "com.apple.Notes", name: "Notes"))
        privacy.ignore(IgnoredApp(bundleID: "com.1password.1password", name: "1Password"))  // already on the list
        #expect(privacy.ignoredApps == [IgnoredApp(bundleID: "com.apple.Notes", name: "Notes")])
        #expect(!privacy.records(.clipboard, at: now, app: "com.apple.Notes"))
        privacy.unignore("com.apple.Notes")
        #expect(privacy.records(.clipboard, at: now, app: "com.apple.Notes"))
    }

    @Test func clipboardSkipsEveryIgnoredApp() {
        var privacy = MemoryPrivacy()
        privacy.ignore(IgnoredApp(bundleID: "com.example.bank", name: "Bank"))
        #expect(ClipboardHistory.shouldSkip(types: [], app: "com.example.bank", ignored: privacy.ignoredBundleIDs))
        #expect(ClipboardHistory.shouldSkip(types: [], app: "com.apple.Passwords"))
        // A list without them still keeps the password apps out.
        #expect(ClipboardHistory.shouldSkip(types: [], app: "com.apple.Passwords", ignored: []))
        #expect(!ClipboardHistory.shouldSkip(types: ["public.utf8-plain-text"], app: "com.apple.TextEdit", ignored: privacy.ignoredBundleIDs))
    }

    @Test func savedWithTheSettingsAndToleratesUnknownSources() throws {
        var settings = SwitcherSettings()
        settings.privacy.set(.sessions, on: false)
        settings.privacy.pause(.oneHour, now: now)
        let data = try JSONEncoder().encode(settings)
        let back = try JSONDecoder().decode(SwitcherSettings.self, from: data)
        #expect(back.privacy == settings.privacy)
        let odd = try JSONDecoder().decode(MemoryPrivacy.self, from: Data(#"{"off":["meetings","telepathy"]}"#.utf8))
        #expect(odd.off == [.meetings])
        // An opt-in source never sits in `off`; settings from before keep screen context off, 30 days.
        let screen = try JSONDecoder().decode(MemoryPrivacy.self, from: Data(#"{"off":["screen"],"on":["screen","notes"]}"#.utf8))
        #expect(screen.off.isEmpty)
        #expect(screen.on == [.screen])
        #expect(!screen.isOn(.screen))
        #expect(screen.screenRetentionDays == 30)
        var consented = MemoryPrivacy()
        consented.set(.screen, on: true)
        consented.screenConsent = now
        consented.screenRetentionDays = 7
        let roundTrip = try JSONDecoder().decode(MemoryPrivacy.self, from: JSONEncoder().encode(consented))
        #expect(roundTrip == consented)
        // Settings saved before privacy existed: everything on.
        let old = try JSONDecoder().decode(SwitcherSettings.self, from: Data(#"{"didOnboard":true}"#.utf8))
        #expect(old.privacy == MemoryPrivacy())
    }

    @Test func sidecarFileSaysWhatIsTrueNow() throws {
        var privacy = MemoryPrivacy()
        privacy.set(.notes, on: false)
        privacy.pause(.oneHour, now: now)
        let paused = try #require(JSONSerialization.jsonObject(with: privacy.sidecarJSON(now: now)) as? [String: Any])
        #expect(paused["paused"] as? Bool == true)
        #expect(paused["paused_until"] as? String == "2026-10-28T21:00:00Z")
        #expect(paused["off"] as? [String] == ["notes", "apps", "screen"])
        #expect(paused["on"] as? [String] == [])
        privacy.set(.apps, on: true)
        let apps = try #require(JSONSerialization.jsonObject(with: privacy.sidecarJSON(now: now)) as? [String: Any])
        #expect(apps["on"] as? [String] == ["apps"] && apps["off"] as? [String] == ["notes", "screen"])
        #expect((paused["ignored_apps"] as? [String])?.contains("com.apple.Passwords") == true)
        // The hour is over: not paused any more.
        let later = try #require(JSONSerialization.jsonObject(with: privacy.sidecarJSON(now: now.addingTimeInterval(7200))) as? [String: Any])
        #expect(later["paused"] as? Bool == false)
        #expect(later["paused_until"] is NSNull)
        privacy.pause(.untilResumed, now: now)
        let forever = try #require(JSONSerialization.jsonObject(with: privacy.sidecarJSON(now: now)) as? [String: Any])
        #expect(forever["paused"] as? Bool == true)
        #expect(forever["paused_until"] is NSNull)
    }

    @Test func forgetDeletesExactlyOneSourcesFiles() throws {
        let support = Fixtures.temp("privacy-support")
        defer { Fixtures.remove(support) }
        let files = MemoryFiles(support: support)
        let fm = FileManager.default
        try fm.createDirectory(at: files.meetingsFolder, withIntermediateDirectories: true)
        try fm.createDirectory(at: files.connectorsFolder, withIntermediateDirectories: true)
        try "{}".write(to: files.meetingsFolder.appending(path: "2026-10-12-kickoff.json"), atomically: true, encoding: .utf8)
        try "{}".write(to: files.meetingsFolder.appending(path: "2026-10-20-review.json"), atomically: true, encoding: .utf8)
        try "x".write(to: files.meetingsFolder.appending(path: "jamie-sync.state"), atomically: true, encoding: .utf8)
        try "# feed".write(to: files.meetingFeed, atomically: true, encoding: .utf8)
        try "{}".write(to: files.calendarSnapshot, atomically: true, encoding: .utf8)
        try "{}".write(to: files.connectorsFolder.appending(path: "vault.json"), atomically: true, encoding: .utf8)
        // Another tool's calendar in connectors/ is a notes snapshot, not Starnotch's calendar.
        try "{}".write(to: files.connectorsFolder.appending(path: "calendar.json"), atomically: true, encoding: .utf8)
        try "{\"text\":\"a\"}\n{\"text\":\"b\"}\n\n".write(to: files.captureQueue, atomically: true, encoding: .utf8)
        try "{}".write(to: files.privacyFile, atomically: true, encoding: .utf8)

        #expect(files.count(.meetings) == 2)
        #expect(files.count(.captures) == 2)
        #expect(files.count(.notes) == 2)
        #expect(files.count(.clipboard) == 0)

        let gone = files.forget(.meetings)
        #expect(gone.map(\.lastPathComponent).sorted() == ["2026-10-12-kickoff.json", "2026-10-20-review.json", "Meeting-Agent.md", "calendar-today.json"])
        // The sync state, the notes and the captures stay.
        #expect(fm.fileExists(atPath: files.meetingsFolder.appending(path: "jamie-sync.state").path))
        #expect(fm.fileExists(atPath: files.connectorsFolder.appending(path: "vault.json").path))
        #expect(fm.fileExists(atPath: files.connectorsFolder.appending(path: "calendar.json").path))
        #expect(files.count(.captures) == 2)
        try fm.createDirectory(at: files.wikiIndex.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "[]".write(to: files.wikiIndex, atomically: true, encoding: .utf8)
        try "x".write(to: files.vaultIndex, atomically: true, encoding: .utf8)
        #expect(files.count(.notes) == 2)  // the index and the wiki are no snapshots
        files.forget(.notes)
        #expect(!fm.fileExists(atPath: files.connectorsFolder.appending(path: "vault.json").path))
        #expect(!fm.fileExists(atPath: files.wikiIndex.path) && !fm.fileExists(atPath: files.vaultIndex.path))
        files.forget(.captures)
        #expect(!fm.fileExists(atPath: files.captureQueue.path))
        #expect(fm.fileExists(atPath: files.privacyFile.path))
    }

    @Test func calendarSnapshotOnlyWhileMeetingsRecord() throws {
        let folder = Fixtures.temp("privacy-calendar")
        defer { Fixtures.remove(folder) }
        let url = MemoryFiles(support: folder).calendarSnapshot
        let events = [CalendarSnapshotEvent(title: "Design review", start: now, end: now.addingTimeInterval(1800),
                                            location: "Room 2", attendees: ["Lena", "Max"], link: "https://meet.google.com/abc")]
        var privacy = MemoryPrivacy()
        privacy.pause(.oneHour, now: now)
        #expect(!CalendarSnapshot.write(events, to: url, privacy: privacy, now: now))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        privacy.resume()
        privacy.set(.meetings, on: false)
        #expect(!CalendarSnapshot.write(events, to: url, privacy: privacy, now: now))
        privacy.set(.meetings, on: true)
        #expect(CalendarSnapshot.write(events, to: url, privacy: privacy, now: now, timeZone: TimeZone(identifier: "UTC")!))
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let today = try #require(object["today"] as? [[String: Any]])
        #expect(object["name"] as? String == "Calendar")
        #expect(today.first?["title"] as? String == "Design review")
        #expect(today.first?["date"] as? String == "2026-10-28T20:00:00Z")
        #expect(today.first?["attendees"] as? String == "Lena, Max")
        #expect(today.first?["url"] as? String == "https://meet.google.com/abc")
        #expect(today.first?["description"] as? String == "until 2026-10-28T20:30:00Z · Room 2 · with Lena, Max")
    }
}

/// Tara's memory in AI apps: every config write against a temporary home only.
@Suite struct MemorySetupTests {
    static func withAgent(_ paths: SetupPaths) throws {
        let uv = paths.home.appending(path: ".local/bin/uv")
        try "#!/bin/bash\n".write(to: uv, atomically: true, encoding: .utf8)
        chmod(uv.path, 0o755)
        try FileManager.default.createDirectory(at: paths.agentFolder, withIntermediateDirectories: true)
        try "".write(to: paths.agentFolder.appending(path: "memory_mcp.py"), atomically: true, encoding: .utf8)
    }

    @Test func claudeDesktopKeepsOtherServersAndRemovesExactly() throws {
        let paths = SetupSandbox.make()
        defer { Fixtures.remove(paths.home) }
        // Without Claude Desktop's folder, nothing happens.
        #expect(throws: SetupError.self) { try SetupActions.installMemory(.memoryClaudeDesktop, paths) }
        try Self.withAgent(paths)
        let file = paths.claudeDesktopConfig
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"mcpServers":{"notes":{"command":"/bin/notes"}},"globalShortcut":"Alt+Space"}"#.write(to: file, atomically: true, encoding: .utf8)
        let entry = try SetupActions.installMemory(.memoryClaudeDesktop, paths)
        #expect(SetupSandbox.exists(entry.backup))
        let servers = try #require(SetupSandbox.json(file)["mcpServers"] as? [String: Any])
        let ours = try #require(servers["starnotch-memory"] as? [String: Any])
        #expect(ours["command"] as? String == paths.home.appending(path: ".local/bin/uv").path)
        #expect(ours["args"] as? [String] == ["run", "--directory", paths.agentFolder.path, "python", "memory_mcp.py"])
        #expect(servers["notes"] != nil)
        #expect(try SetupActions.installMemory(.memoryClaudeDesktop, paths).note == "Was already set up.")
        try SetupActions.removeMemory(.memoryClaudeDesktop, paths, entry: entry)
        let after = SetupSandbox.json(file)
        #expect((after["mcpServers"] as? [String: Any])?.keys.sorted() == ["notes"])
        #expect(after["globalShortcut"] as? String == "Alt+Space")
    }

    @Test func aServerOfTheSameNameComesBackAndAChangedOneStays() throws {
        let paths = SetupSandbox.make()
        defer { Fixtures.remove(paths.home) }
        try Self.withAgent(paths)
        try FileManager.default.createDirectory(at: paths.cursorHome, withIntermediateDirectories: true)
        try #"{"mcpServers":{"starnotch-memory":{"command":"/opt/mine"}}}"#.write(to: paths.cursorMCPConfig, atomically: true, encoding: .utf8)
        let entry = try SetupActions.installMemory(.memoryCursor, paths)
        try SetupActions.removeMemory(.memoryCursor, paths, entry: entry)
        let back = (SetupSandbox.json(paths.cursorMCPConfig)["mcpServers"] as? [String: Any])?["starnotch-memory"] as? [String: Any]
        #expect(back?["command"] as? String == "/opt/mine")

        // Ours, then changed by hand: Remove leaves it.
        let again = try SetupActions.installMemory(.memoryCursor, paths)
        try #"{"mcpServers":{"starnotch-memory":{"command":"/opt/edited","args":[]}}}"#.write(to: paths.cursorMCPConfig, atomically: true, encoding: .utf8)
        #expect(throws: SetupError.self) { try SetupActions.removeMemory(.memoryCursor, paths, entry: again) }
        #expect(SetupSandbox.read(paths.cursorMCPConfig).contains("/opt/edited"))
    }

    @Test func aFileWeCreatedGoesAgainAndInvalidJSONIsLeftAlone() throws {
        let paths = SetupSandbox.make()
        defer { Fixtures.remove(paths.home) }
        try Self.withAgent(paths)
        try FileManager.default.createDirectory(at: paths.cursorHome, withIntermediateDirectories: true)
        let entry = try SetupActions.installMemory(.memoryCursor, paths)
        #expect(entry.backup == nil)
        #expect(FileManager.default.fileExists(atPath: paths.cursorMCPConfig.path))
        try SetupActions.removeMemory(.memoryCursor, paths, entry: entry)
        #expect(!FileManager.default.fileExists(atPath: paths.cursorMCPConfig.path))

        try "{ broken".write(to: paths.cursorMCPConfig, atomically: true, encoding: .utf8)
        #expect(throws: SetupError.self) { try SetupActions.installMemory(.memoryCursor, paths) }
        #expect(SetupSandbox.read(paths.cursorMCPConfig) == "{ broken")
    }

    @Test func claudeCodeThroughItsCommand() throws {
        let paths = SetupSandbox.make()
        defer { Fixtures.remove(paths.home) }
        try Self.withAgent(paths)
        _ = try SetupActions.installMemory(.memoryClaudeCode, paths)
        let calls = SetupSandbox.read(paths.home.appending(path: "claude-calls.log"))
        #expect(calls.contains("mcp add --scope user starnotch-memory -- \(paths.home.appending(path: ".local/bin/uv").path) run --directory \(paths.agentFolder.path) python memory_mcp.py"))
        try SetupActions.removeMemory(.memoryClaudeCode, paths, entry: nil)
        #expect(SetupSandbox.read(paths.home.appending(path: "claude-calls.log")).hasSuffix("mcp remove --scope user starnotch-memory\n"))
    }

    @Test func chatGPTGetsABlockInCodexConfigThatComesOutExactly() throws {
        let paths = SetupSandbox.make()
        defer { Fixtures.remove(paths.home) }
        try Self.withAgent(paths)
        let original = "model = \"gpt-6.1\"\n\n[mcp_servers.notes]\ncommand = \"/bin/notes\"\n"
        try original.write(to: paths.codexConfig, atomically: true, encoding: .utf8)
        let entry = try SetupActions.installMemory(.memoryChatGPT, paths)
        let text = SetupSandbox.read(paths.codexConfig)
        #expect(text.hasPrefix(original + "\n# >>> Starnotch"))
        #expect(text.contains("[mcp_servers.starnotch-memory]\ncommand = \"\(paths.home.appending(path: ".local/bin/uv").path)\"\n"))
        #expect(text.contains("args = [\"run\", \"--directory\", \"\(paths.agentFolder.path)\", \"python\", \"memory_mcp.py\"]"))
        #expect(SetupSandbox.exists(entry.backup))
        #expect(try SetupActions.installMemory(.memoryChatGPT, paths).note == "Was already set up.")
        try SetupActions.removeMemory(.memoryChatGPT, paths, entry: entry)
        #expect(SetupSandbox.read(paths.codexConfig) == original)
    }

    @Test func codexConfigWithoutTrailingNewlineOrEmpty() throws {
        let paths = SetupSandbox.make()
        defer { Fixtures.remove(paths.home) }
        try Self.withAgent(paths)
        try "model = \"x\"".write(to: paths.codexConfig, atomically: true, encoding: .utf8)
        let entry = try SetupActions.installMemory(.memoryChatGPT, paths)
        #expect(SetupSandbox.read(paths.codexConfig).hasPrefix("model = \"x\"\n\n# >>> Starnotch"))
        try SetupActions.removeMemory(.memoryChatGPT, paths, entry: entry)
        #expect(SetupSandbox.read(paths.codexConfig) == "model = \"x\"\n")

        try FileManager.default.removeItem(at: paths.codexConfig)
        let created = try SetupActions.installMemory(.memoryChatGPT, paths)
        #expect(created.previous == "created")
        #expect(SetupSandbox.read(paths.codexConfig).hasPrefix("# >>> Starnotch"))
        try SetupActions.removeMemory(.memoryChatGPT, paths, entry: created)
        #expect(!FileManager.default.fileExists(atPath: paths.codexConfig.path))
    }

    @Test func codexConfigThatAlreadyHasTheServerIsNotTouched() throws {
        let paths = SetupSandbox.make()
        defer { Fixtures.remove(paths.home) }
        try Self.withAgent(paths)
        for text in ["[mcp_servers.starnotch-memory]\ncommand = \"/x\"\n", "[mcp_servers.\"starnotch-memory\"]\ncommand = \"/x\"\n",
                     "mcp_servers = { a = { command = \"/x\" } }\n"] {
            try text.write(to: paths.codexConfig, atomically: true, encoding: .utf8)
            #expect(throws: SetupError.self) { try SetupActions.installMemory(.memoryChatGPT, paths) }
            #expect(SetupSandbox.read(paths.codexConfig) == text)
        }
    }

    @Test func codexConfigWithTheServerUnderMcpServersOrInCRLFIsNotTouched() throws {
        let paths = SetupSandbox.make()
        defer { Fixtures.remove(paths.home) }
        try Self.withAgent(paths)
        for text in ["[mcp_servers]\nstarnotch-memory = { command = \"/x\" }\n",
                     "model = \"x\"\r\n[mcp_servers.starnotch-memory]\r\ncommand = \"/x\"\r\n",
                     "[mcp_servers.starnotch-memory.env]\nA = \"1\"\n"] {
            try text.write(to: paths.codexConfig, atomically: true, encoding: .utf8)
            #expect(throws: SetupError.self) { try SetupActions.installMemory(.memoryChatGPT, paths) }
            #expect(SetupSandbox.read(paths.codexConfig) == text)
        }
        // Another server under [mcp_servers] is fine.
        try "[mcp_servers]\nnotes = { command = \"/x\" }\n".write(to: paths.codexConfig, atomically: true, encoding: .utf8)
        #expect(throws: Never.self) { try SetupActions.installMemory(.memoryChatGPT, paths) }
    }

    @Test func codexConfigInCRLFComesBackExactly() throws {
        let paths = SetupSandbox.make()
        defer { Fixtures.remove(paths.home) }
        try Self.withAgent(paths)
        let original = "model = \"x\"\r\n"
        try original.write(to: paths.codexConfig, atomically: true, encoding: .utf8)
        let entry = try SetupActions.installMemory(.memoryChatGPT, paths)
        #expect(SetupSandbox.read(paths.codexConfig).hasPrefix(original + "\n# >>> Starnotch"))
        try SetupActions.removeMemory(.memoryChatGPT, paths, entry: entry)
        #expect(SetupSandbox.read(paths.codexConfig) == original)
    }

    @Test func jsonConfigWithoutServersLosesTheKeyAgainAndSymlinksStay() throws {
        let paths = SetupSandbox.make()
        defer { Fixtures.remove(paths.home) }
        try Self.withAgent(paths)
        try FileManager.default.createDirectory(at: paths.cursorHome, withIntermediateDirectories: true)
        let real = paths.home.appending(path: "dotfiles-mcp.json")
        try #"{"theme":"dark"}"#.write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: paths.cursorMCPConfig, withDestinationURL: real)
        let entry = try SetupActions.installMemory(.memoryCursor, paths)
        #expect(SetupSandbox.read(real).contains("starnotch-memory"))
        try SetupActions.removeMemory(.memoryCursor, paths, entry: entry)
        let after = SetupSandbox.json(real)
        #expect(after["mcpServers"] == nil && after["theme"] as? String == "dark")
        let type = try FileManager.default.attributesOfItem(atPath: paths.cursorMCPConfig.path)[.type] as? FileAttributeType
        #expect(type == .typeSymbolicLink)
    }

    @Test func tomlStringsAreEscaped() {
        #expect(SetupActions.tomlString(#"/Users/a "b"/c\d"#) == #""/Users/a \"b\"/c\\d""#)
    }

    @Test func memoryItemsAreRemovableAndOffTheAgentList() {
        for item in SetupItem.memoryItems {
            #expect(item.isRemovable)
            #expect(item.appName != nil)
        }
    }
}
