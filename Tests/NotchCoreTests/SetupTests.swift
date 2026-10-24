import Testing
import TestSupport
@testable import NotchCore

/// The setup page's actions, against a temporary home only.
@Suite struct SetupTests {
    @Test func statusLineChainsTheOldOneAndRestoresIt() throws {
        let paths = SetupSandbox.make()
        defer { Fixtures.remove(paths.home) }
        let entry = try SetupActions.installStatusLine(paths)
        let command = try #require(SetupSandbox.statusCommand(paths))
        // The bridge first, then the old command unchanged (quoted for sh -c).
        #expect(command.contains("statusline-bridge.sh"))
        #expect(command.hasSuffix("sh -c 'bash ~/.claude/my status.sh'"))
        #expect(SetupSandbox.value(paths, "theme") == "dark")
        #expect(SetupSandbox.exists(entry.backup))
        #expect(SetupSandbox.exists(paths.installedBridge.path))
        // Again: nothing doubles.
        #expect(try SetupActions.installStatusLine(paths).note == "Was already set up.")
        try SetupActions.removeStatusLine(paths, entry: entry)
        #expect(SetupSandbox.statusCommand(paths) == "bash ~/.claude/my status.sh")
        #expect(!SetupSandbox.exists(paths.installedBridge.path))
    }

    @Test func statusLineWithoutOneBeforeIsRemovedCompletely() throws {
        let paths = SetupSandbox.make()
        defer { Fixtures.remove(paths.home) }
        try #"{"model":"opus"}"#.write(to: paths.claudeSettings, atomically: true, encoding: .utf8)
        let entry = try SetupActions.installStatusLine(paths)
        #expect(SetupSandbox.statusCommand(paths)?.contains("sh -c") == false)
        try SetupActions.removeStatusLine(paths, entry: entry)
        #expect(SetupSandbox.json(paths.claudeSettings)["statusLine"] == nil)
        #expect(SetupSandbox.value(paths, "model") == "opus")
    }

    @Test func aChangedStatusLineIsLeftAlone() throws {
        let paths = SetupSandbox.make()
        defer { Fixtures.remove(paths.home) }
        let entry = try SetupActions.installStatusLine(paths)
        try #"{"statusLine":{"type":"command","command":"mine"}}"#.write(to: paths.claudeSettings, atomically: true, encoding: .utf8)
        #expect(throws: SetupError.self) { try SetupActions.removeStatusLine(paths, entry: entry) }
        #expect(SetupSandbox.statusCommand(paths) == "mine")
    }

    @Test func invalidSettingsAreNotTouched() throws {
        let paths = SetupSandbox.make()
        defer { Fixtures.remove(paths.home) }
        try "{ not json".write(to: paths.claudeSettings, atomically: true, encoding: .utf8)
        #expect(throws: SetupError.self) { try SetupActions.installStatusLine(paths) }
        #expect(SetupSandbox.read(paths.claudeSettings) == "{ not json")
    }

    @Test func pluginFromGitHubElseTheBundledFolder() throws {
        let paths = SetupSandbox.make()
        defer { Fixtures.remove(paths.home) }
        let entry = try SetupActions.installClaudePlugin(paths)
        #expect(entry.previous == "juliokoelle/starnotch")
        #expect(SetupSandbox.read(paths.home.appending(path: "claude-calls.log"))
                == "plugin marketplace add juliokoelle/starnotch\nplugin install starnotch-approvals@starnotch\n")
        try SetupActions.removeClaudePlugin(paths)
        #expect(SetupSandbox.read(paths.home.appending(path: "claude-calls.log")).hasSuffix(
            "plugin uninstall starnotch-approvals@starnotch\nplugin marketplace remove starnotch\n"))

        let offline = SetupSandbox.make(failGitHub: true)
        defer { Fixtures.remove(offline.home) }
        let local = try SetupActions.installClaudePlugin(offline)
        #expect(local.previous?.hasSuffix("integrations/claude-code") == true)
    }

    @Test func codexHookInstallsAndRemoves() throws {
        let paths = SetupSandbox.make()
        defer { Fixtures.remove(paths.home) }
        let entry = try SetupActions.installCodexHook(paths)
        #expect(SetupSandbox.hasCodexHook(paths))
        #expect(SetupSandbox.exists(entry.backup))
        try SetupActions.removeCodexHook(paths)
        #expect(!SetupSandbox.hasCodexHook(paths))
    }

    @Test func shellHookAddsAndRemovesItsBlockOnly() throws {
        let paths = SetupSandbox.make()
        defer { Fixtures.remove(paths.home) }
        let entry = try SetupActions.installShellHook(paths)
        let zshrc = SetupSandbox.read(paths.zshrc)
        #expect(zshrc.hasPrefix("export PATH=$HOME/bin:$PATH\n"))
        #expect(zshrc.contains("source '\(paths.shellSnippet.path)'"))
        #expect(SetupSandbox.exists(entry.backup))
        #expect(try SetupActions.installShellHook(paths).note == "Was already set up.")
        try SetupActions.removeShellHook(paths)
        #expect(SetupSandbox.read(paths.zshrc) == "export PATH=$HOME/bin:$PATH\n")
        #expect(!SetupSandbox.exists(paths.shellSnippet.path))
    }

    @Test func ledgerRoundTrip() throws {
        let paths = SetupSandbox.make()
        defer { Fixtures.remove(paths.home) }
        var ledger = SetupLedger()
        ledger.record(.init(item: .statusLine, at: UTC.date("2026-10-24 10:00"), backup: "/b", previous: "null"))
        ledger.record(.init(item: .statusLine, at: UTC.date("2026-10-24 11:00")))
        #expect(ledger.entries.count == 1)
        try ledger.save(paths.ledgerFile)
        #expect(SetupLedger.load(paths.ledgerFile) == ledger)
        ledger.forget(.statusLine)
        #expect(ledger.entry(.statusLine) == nil)
    }
}
