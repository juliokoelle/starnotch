import Foundation
import Testing
import TestSupport
@testable import NotchCore

/// The approvals plugin's registration heals itself: the decision from Claude Code's registry and
/// the commands it runs, against a temporary home and a fake runner only.
@Suite struct ClaudePluginCheckTests {
    static let copy = URL(fileURLWithPath: "/support/integrations/claude-code")

    static func marketplaces(_ source: String?) -> Data {
        guard let source else { return Data(#"{"other":{"source":{"source":"github","repo":"someone/else"}}}"#.utf8) }
        return Data(#"{"starnotch":{"source":\#(source),"installLocation":"/x"}}"#.utf8)
    }

    static func directory(_ path: String) -> String { #"{"source":"directory","path":"\#(path)"}"# }
    static let github = #"{"source":"github","repo":"juliokoelle/starnotch"}"#
    static let installed = Data(#"{"version":2,"plugins":{"starnotch-approvals@starnotch":[{"scope":"user","version":"0.1.0"}]}}"#.utf8)
    static let notInstalled = Data(#"{"version":2,"plugins":{}}"#.utf8)
    static let enabled = Data(#"{"enabledPlugins":{"starnotch-approvals@starnotch":true}}"#.utf8)

    static func decide(_ marketplaces: Data?, installed: Data? = installed, settings: Data? = enabled,
                       copyStale: Bool = false, existing: Set<String> = [copy.path]) -> ClaudePluginRepair {
        ClaudePluginCheck.decide(marketplaces: marketplaces, installed: installed, settings: settings,
                                 stableCopy: copy, copyStale: copyStale, exists: { existing.contains($0) })
    }

    // MARK: The decision

    @Test func theStableCopyOrGitHubIsFine() {
        #expect(Self.decide(Self.marketplaces(Self.directory(Self.copy.path))) == .fine)
        #expect(Self.decide(Self.marketplaces(Self.directory(Self.copy.path + "/")), existing: [Self.copy.path + "/"]) == .fine)
        #expect(Self.decide(Self.marketplaces(Self.github)) == .fine)
        #expect(Self.decide(Self.marketplaces(Self.github), existing: []) == .fine)
    }

    @Test func aStaleCopyIsOnlyRefreshed() {
        #expect(Self.decide(Self.marketplaces(Self.directory(Self.copy.path)), copyStale: true) == .refreshCopy)
        #expect(Self.decide(Self.marketplaces(Self.github), copyStale: true) == .refreshCopy)
    }

    @Test func aFolderElsewhereOrGoneIsRegisteredAgain() {
        // A build folder that still exists, but isn't the app's copy.
        #expect(Self.decide(Self.marketplaces(Self.directory("/old/build/integrations/claude-code")),
                            existing: [Self.copy.path, "/old/build/integrations/claude-code"]) == .reregister)
        // A deleted build folder.
        #expect(Self.decide(Self.marketplaces(Self.directory("/old/build/integrations/claude-code"))) == .reregister)
        // The app's copy, deleted.
        #expect(Self.decide(Self.marketplaces(Self.directory(Self.copy.path)), existing: []) == .reregister)
        // Another GitHub repository, another kind of source, or none at all.
        #expect(Self.decide(Self.marketplaces(#"{"source":"github","repo":"someone/fork"}"#)) == .reregister)
        #expect(Self.decide(Self.marketplaces(#"{"source":"url","url":"https://example.com/m.json"}"#)) == .reregister)
        #expect(Self.decide(Self.marketplaces(nil)) == .reregister)
    }

    @Test func aMissingPluginIsInstalled() {
        #expect(Self.decide(Self.marketplaces(Self.github), installed: Self.notInstalled) == .install)
        // Not in enabledPlugins at all counts as missing; so does a missing settings file.
        #expect(Self.decide(Self.marketplaces(Self.github), settings: Data(#"{"model":"opus"}"#.utf8)) == .install)
        #expect(Self.decide(Self.marketplaces(Self.directory(Self.copy.path)), settings: nil) == .install)
    }

    @Test func aPluginTheUserSwitchedOffStaysOff() {
        let off = Data(#"{"enabledPlugins":{"starnotch-approvals@starnotch":false}}"#.utf8)
        #expect(Self.decide(Self.marketplaces(Self.github), settings: off) == .fine)
        #expect(Self.decide(Self.marketplaces(Self.directory("/gone")), settings: off) == .fine)
        #expect(Self.decide(Self.marketplaces(Self.directory("/gone")), installed: Self.notInstalled, settings: off) == .fine)
        // Only the app's own copy may still be refreshed.
        #expect(Self.decide(Self.marketplaces(Self.directory("/gone")), settings: off, copyStale: true) == .refreshCopy)
    }

    @Test func anUnreadableRegistryLeavesEverythingAlone() {
        let broken = Data("{ not json".utf8)
        let gone = Self.marketplaces(Self.directory("/gone"))
        #expect(Self.decide(broken) == .fine)
        #expect(Self.decide(gone, installed: broken) == .fine)
        #expect(Self.decide(gone, settings: broken) == .fine)
        #expect(Self.decide(gone, installed: Data(#"{"version":2}"#.utf8)) == .fine)
        // Files that aren't there: Claude Code may keep them elsewhere now.
        #expect(Self.decide(nil) == .fine)
        #expect(Self.decide(gone, installed: nil) == .fine)
        #expect(Self.decide(broken, copyStale: true) == .fine)
    }

    // MARK: The launch check's commands

    /// Records every command; answers with `answer` (by the joined arguments' prefix).
    final class FakeRunner: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        var answers: [String: (Int32, String)] = [:]
        var calls: [String] { lock.withLock { _calls } }

        var run: SetupRunner {
            { _, arguments, environment in
                let line = arguments.joined(separator: " ")
                self.lock.withLock { self._calls.append(line) }
                precondition(environment["HOME"]?.contains("setup-home") == true, "a real HOME")
                return self.answers.first { line.hasPrefix($0.key) }?.value ?? (0, "")
            }
        }
    }

    static func home(marketplace: String?, installed: Data = installed, settings: Data? = enabled, setUp: Bool = true)
        -> (SetupPaths, SetupLedger) {
        let paths = SetupSandbox.make()
        let plugins = paths.home.appending(path: ".claude/plugins")
        try? FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        try? marketplaces(marketplace).write(to: paths.knownMarketplaces)
        try? installed.write(to: paths.installedPlugins)
        if let settings { try? settings.write(to: paths.claudeSettings) }
        var ledger = SetupLedger()
        if setUp { ledger.record(.init(item: .claudePlugin, at: Date(), previous: "/old", note: "Marketplace: /old.")) }
        return (paths, ledger)
    }

    @Test func aDeletedFolderIsRegisteredAgainFromTheCopy() throws {
        let (paths, ledger) = Self.home(marketplace: Self.directory("/deleted/build/integrations/claude-code"))
        defer { Fixtures.remove(paths.home) }
        let fake = FakeRunner()
        #expect(try SetupActions.checkClaudePlugin(paths, ledger: ledger, run: fake.run) == .reregister)
        #expect(fake.calls == ["plugin marketplace remove starnotch",
                               "plugin marketplace add \(paths.claudePluginCopy.path)",
                               "plugin install starnotch-approvals@starnotch --scope user"])
        #expect(SetupActions.contents(paths.claudePluginCopy) == SetupActions.contents(try #require(paths.claudePluginBundle)))
        #expect(SetupActions.contents(paths.claudePluginCopy)?["starnotch-approvals/scripts/ask-notch.sh"] != nil)
        // Claude Code's files are only read.
        #expect(SetupSandbox.read(paths.knownMarketplaces).contains("/deleted/build"))
    }

    @Test func aStaleFolderThatStillExistsIsRegisteredAgain() throws {
        let (paths, ledger) = Self.home(marketplace: nil)
        defer { Fixtures.remove(paths.home) }
        let old = paths.home.appending(path: "old-build/integrations/claude-code")
        try FileManager.default.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: try #require(paths.claudePluginBundle), to: old)
        try Self.marketplaces(Self.directory(old.path)).write(to: paths.knownMarketplaces)
        let fake = FakeRunner()
        #expect(try SetupActions.checkClaudePlugin(paths, ledger: ledger, run: fake.run) == .reregister)
        #expect(fake.calls.first == "plugin marketplace remove starnotch")
        #expect(fake.calls.count == 3)
    }

    @Test func gitHubFineDoesNothing() throws {
        let (paths, ledger) = Self.home(marketplace: Self.github)
        defer { Fixtures.remove(paths.home) }
        let fake = FakeRunner()
        #expect(try SetupActions.checkClaudePlugin(paths, ledger: ledger, run: fake.run) == .fine)
        #expect(fake.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: paths.claudePluginCopy.path))
    }

    @Test func aMissingPluginIsOnlyInstalled() throws {
        let (paths, ledger) = Self.home(marketplace: Self.github, installed: Self.notInstalled)
        defer { Fixtures.remove(paths.home) }
        let fake = FakeRunner()
        #expect(try SetupActions.checkClaudePlugin(paths, ledger: ledger, run: fake.run) == .install)
        #expect(fake.calls == ["plugin install starnotch-approvals@starnotch --scope user"])
    }

    @Test func aDisabledPluginIsLeftAlone() throws {
        let off = Data(#"{"enabledPlugins":{"starnotch-approvals@starnotch":false}}"#.utf8)
        let (paths, ledger) = Self.home(marketplace: Self.directory("/gone"), settings: off)
        defer { Fixtures.remove(paths.home) }
        let fake = FakeRunner()
        #expect(try SetupActions.checkClaudePlugin(paths, ledger: ledger, run: fake.run) == .fine)
        #expect(fake.calls.isEmpty)
    }

    @Test func withoutTheLedgerItemNothingIsReadOrRun() throws {
        let (paths, ledger) = Self.home(marketplace: Self.directory("/gone"), installed: Self.notInstalled, setUp: false)
        defer { Fixtures.remove(paths.home) }
        let fake = FakeRunner()
        #expect(try SetupActions.checkClaudePlugin(paths, ledger: ledger, run: fake.run) == .fine)
        #expect(fake.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: paths.claudePluginCopy.path))
    }

    @Test func unreadableJSONDoesNothing() throws {
        let (paths, ledger) = Self.home(marketplace: Self.directory("/gone"))
        defer { Fixtures.remove(paths.home) }
        try "{ not json".write(to: paths.knownMarketplaces, atomically: true, encoding: .utf8)
        let fake = FakeRunner()
        #expect(try SetupActions.checkClaudePlugin(paths, ledger: ledger, run: fake.run) == .fine)
        #expect(fake.calls.isEmpty)
        #expect(SetupSandbox.read(paths.knownMarketplaces) == "{ not json")
    }

    @Test func aChangedCopyIsRefreshedWithoutCommands() throws {
        let (paths, ledger) = Self.home(marketplace: nil)
        defer { Fixtures.remove(paths.home) }
        try SetupActions.placeClaudePluginCopy(paths)
        try Self.marketplaces(Self.directory(paths.claudePluginCopy.path)).write(to: paths.knownMarketplaces)
        let script = paths.claudePluginCopy.appending(path: "starnotch-approvals/scripts/ask-notch.sh")
        try "old".write(to: script, atomically: true, encoding: .utf8)
        #expect(SetupActions.isClaudePluginCopyStale(paths))
        let fake = FakeRunner()
        #expect(try SetupActions.checkClaudePlugin(paths, ledger: ledger, run: fake.run) == .refreshCopy)
        #expect(fake.calls.isEmpty)
        #expect(!SetupActions.isClaudePluginCopyStale(paths))
        #expect(SetupSandbox.read(script) != "old")
        // The support folder stays private.
        let mode = try FileManager.default.attributesOfItem(atPath: paths.claudePluginCopy.deletingLastPathComponent().path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
        // The next launch: nothing left to do.
        #expect(try SetupActions.checkClaudePlugin(paths, ledger: ledger, run: fake.run) == .fine)
    }

    @Test func aFailedStepKeepsAShortReason() throws {
        let (paths, ledger) = Self.home(marketplace: Self.directory("/gone"))
        defer { Fixtures.remove(paths.home) }
        let fake = FakeRunner()
        fake.answers["plugin marketplace add"] = (1, "Error: something broke\n  at line 3\n")
        #expect(throws: SetupError.failed("Couldn't add the marketplace: Error: something broke")) {
            try SetupActions.checkClaudePlugin(paths, ledger: ledger, run: fake.run)
        }
        #expect(fake.calls.count == 2)  // no install after a failed add, no retry
    }

    // MARK: Set up and Remove

    @Test func alreadyAddedButStaleIsPointedAtTheCopy() throws {
        let (paths, _) = Self.home(marketplace: Self.directory("/deleted/build/integrations/claude-code"))
        defer { Fixtures.remove(paths.home) }
        let fake = FakeRunner()
        fake.answers["plugin marketplace add juliokoelle/starnotch"] = (1, "Marketplace 'starnotch' is already installed")
        let entry = try SetupActions.installClaudePlugin(paths, run: fake.run)
        #expect(fake.calls == ["plugin marketplace add juliokoelle/starnotch",
                               "plugin marketplace remove starnotch",
                               "plugin marketplace add \(paths.claudePluginCopy.path)",
                               "plugin install starnotch-approvals@starnotch"])
        #expect(entry.previous == paths.claudePluginCopy.path)
        #expect(entry.note?.hasSuffix("Restart running sessions.") == true)
    }

    @Test func alreadyAddedFromGitHubStaysAsItIs() throws {
        let (paths, _) = Self.home(marketplace: Self.github)
        defer { Fixtures.remove(paths.home) }
        let fake = FakeRunner()
        fake.answers["plugin marketplace add"] = (0, "Marketplace 'starnotch' is already installed")
        let entry = try SetupActions.installClaudePlugin(paths, run: fake.run)
        #expect(fake.calls == ["plugin marketplace add juliokoelle/starnotch", "plugin install starnotch-approvals@starnotch"])
        #expect(entry.previous == "juliokoelle/starnotch")
        #expect(!FileManager.default.fileExists(atPath: paths.claudePluginCopy.path))
    }

    @Test func removeTakesTheCopyAlong() throws {
        let paths = SetupSandbox.make(failGitHub: true)
        defer { Fixtures.remove(paths.home) }
        let entry = try SetupActions.installClaudePlugin(paths)
        #expect(entry.previous == paths.claudePluginCopy.path)
        #expect(FileManager.default.fileExists(atPath: paths.claudePluginCopy.appending(path: ".claude-plugin/marketplace.json").path))
        try SetupActions.removeClaudePlugin(paths)
        #expect(!FileManager.default.fileExists(atPath: paths.claudePluginCopy.path))
    }
}
