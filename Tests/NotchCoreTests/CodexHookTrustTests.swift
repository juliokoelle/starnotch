import Foundation
import Testing
import TestSupport
@testable import NotchCore

/// Whether Codex runs the approvals hook: hooks.json for its place, config.toml for the trust.
@Suite struct CodexHookTrustTests {
    static let hooksPath = "/Users/test/.codex/hooks.json"
    static let ours = #"{"type":"command","command":"\"/Users/test/.codex/hooks/starnotch-ask-notch.sh\" codex","timeout":75,"statusMessage":"Asking in the notch"}"#
    static let other = #"{"type":"command","command":"bash other.sh"}"#

    /// A hooks.json whose PermissionRequest groups hold these handlers.
    static func hooks(_ groups: [[String]]) -> Data {
        let list = groups.map { #"{"hooks":["# + $0.joined(separator: ",") + "]}" }.joined(separator: ",")
        return Data(#"{"hooks":{"SessionStart":[{"hooks":[\#(other)]}],"PermissionRequest":[\#(list)]}}"#.utf8)
    }

    static func status(_ hooks: Data?, _ config: String?, lastRequest: Date? = nil, now: Date = UTC.date("2026-11-04 10:00")) -> CodexHookTrust.Status {
        CodexHookTrust.status(hooks: hooks, config: config, hooksPaths: [hooksPath], lastRequest: lastRequest, now: now)
    }

    static func trusted(_ key: String, enabled: Bool? = nil) -> String {
        "model = \"gpt\"\n\n[hooks.state.\"\(key)\"]\ntrusted_hash = \"sha256:abc\"\n" + (enabled.map { "enabled = \($0)\n" } ?? "") + "\n[mcp_servers.x]\ncommand = \"x\"\n"
    }

    @Test func withoutOurHookItIsNotInstalled() {
        #expect(Self.status(nil, nil) == .notInstalled)
        #expect(Self.status(Self.hooks([[Self.other]]), nil) == .notInstalled)
        #expect(Self.status(Data("not json".utf8), nil) == .notInstalled)
    }

    @Test func installedButNeverTrustedNeedsTrust() {
        #expect(Self.status(Self.hooks([[Self.ours]]), nil) == .needsTrust)
        #expect(Self.status(Self.hooks([[Self.ours]]), "[features]\nhooks = true\n") == .needsTrust)
    }

    @Test func aTrustedHashAtOurPlaceMakesItActive() {
        let config = Self.trusted("\(Self.hooksPath):permission_request:0:0")
        #expect(Self.status(Self.hooks([[Self.ours]]), config) == .active)
    }

    @Test func thePlaceCountsGroupsAndHandlers() {
        // Another group first, and ours second in its group: permission_request:1:1.
        let hooks = Self.hooks([[Self.other], [Self.other, Self.ours]])
        let place = CodexHookTrust.place(in: hooks)
        #expect(place?.group == 1 && place?.handler == 1)
        #expect(Self.status(hooks, Self.trusted("\(Self.hooksPath):permission_request:1:1")) == .active)
        // The other hook's trust isn't ours.
        #expect(Self.status(hooks, Self.trusted("\(Self.hooksPath):permission_request:0:0")) == .needsTrust)
        // Nor a trust for another hooks file.
        #expect(Self.status(hooks, Self.trusted("/Users/other/.codex/hooks.json:permission_request:1:1")) == .needsTrust)
    }

    @Test func switchedOffInCodexWinsOverTrust() {
        let key = "\(Self.hooksPath):permission_request:0:0"
        #expect(Self.status(Self.hooks([[Self.ours]]), Self.trusted(key, enabled: false)) == .switchedOff)
        #expect(Self.status(Self.hooks([[Self.ours]]), Self.trusted(key, enabled: true)) == .active)
        // Switched off before it was ever trusted.
        #expect(Self.status(Self.hooks([[Self.ours]]), "[hooks.state.\"\(key)\"]\nenabled = false # off\n") == .switchedOff)
    }

    @Test func allHooksOffInFeaturesIsSwitchedOff() {
        let key = "\(Self.hooksPath):permission_request:0:0"
        #expect(Self.status(Self.hooks([[Self.ours]]), Self.trusted(key) + "[features]\nhooks = false\n") == .switchedOff)
        #expect(Self.status(Self.hooks([[Self.ours]]), "[features]\ncodex_hooks = false\n") == .switchedOff)
        // Another table's `hooks` key isn't the feature.
        #expect(Self.status(Self.hooks([[Self.ours]]), "[tui]\nhooks = false\n") == .needsTrust)
    }

    @Test func aRecentApprovalThroughTheHookProvesItRuns() {
        let now = UTC.date("2026-11-04 10:00")
        #expect(Self.status(Self.hooks([[Self.ours]]), nil, lastRequest: UTC.date("2026-11-01 09:00"), now: now) == .active)
        #expect(Self.status(Self.hooks([[Self.ours]]), nil, lastRequest: UTC.date("2026-10-20 09:00"), now: now) == .needsTrust)
        // Switched off since: off.
        let off = "[hooks.state.\"\(Self.hooksPath):permission_request:0:0\"]\nenabled = false\n"
        #expect(Self.status(Self.hooks([[Self.ours]]), off, lastRequest: UTC.date("2026-11-04 09:00"), now: now) == .switchedOff)
    }

    @Test func readsTheFilesInCodexsFolder() throws {
        let home = Fixtures.temp("codex-trust")
        defer { Fixtures.remove(home) }
        let hooksFile = home.appending(path: "hooks.json")
        try Self.hooks([[Self.ours]]).write(to: hooksFile)
        #expect(CodexHookTrust.status(codexHome: home) == .needsTrust)
        // The temporary folder sits behind a symlink (/var → /private/var): either form counts.
        for path in [hooksFile.path, hooksFile.resolvingSymlinksInPath().path] {
            try Self.trusted("\(path):permission_request:0:0").write(to: home.appending(path: "config.toml"), atomically: true, encoding: .utf8)
            #expect(CodexHookTrust.status(codexHome: home) == .active)
        }
    }

    @Test func nudgesOnceADayOnlyWhileBlocked() {
        let calendar = UTC.calendar
        let now = UTC.date("2026-11-04 10:00")
        #expect(CodexHookTrust.nudgeDue(.needsTrust, lastShown: nil, now: now, calendar: calendar))
        #expect(CodexHookTrust.nudgeDue(.switchedOff, lastShown: "2026-11-03", now: now, calendar: calendar))
        #expect(!CodexHookTrust.nudgeDue(.needsTrust, lastShown: "2026-11-04", now: now, calendar: calendar))
        #expect(!CodexHookTrust.nudgeDue(.active, lastShown: nil, now: now, calendar: calendar))
        #expect(!CodexHookTrust.nudgeDue(.notInstalled, lastShown: nil, now: now, calendar: calendar))
    }
}
