import Foundation
import Testing
@testable import NotchCore

/// Keep awake with the lid closed: when pmset runs, when it stops, and the exact texts.
@Suite struct LidAwakeTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func onlyOnPowerAndOnlyWithTheRule() {
        var lid = LidAwake()
        #expect(lid.handle(.switchOn(.oneHour, onPower: false, ruleInstalled: true), now: now) == .needsPower)
        #expect(lid.handle(.switchOn(.oneHour, onPower: true, ruleInstalled: false), now: now) == .installRule)
        #expect(!lid.isOn)
        #expect(lid.handle(.switchOn(.oneHour, onPower: true, ruleInstalled: true), now: now) == .enable)
        #expect(lid.state == .on(since: now, until: now.addingTimeInterval(3600)))
    }

    @Test func theLimitEndsIt() {
        var lid = LidAwake()
        _ = lid.handle(.switchOn(.threeHours, onPower: true, ruleInstalled: true), now: now)
        #expect(lid.handle(.tick, now: now.addingTimeInterval(3 * 3600 - 1)) == .none)
        #expect(lid.remaining(now: now.addingTimeInterval(3600)) == 2 * 3600.0)  // a Double: an Int literal compares as AnyHashable and fails
        #expect(lid.handle(.tick, now: now.addingTimeInterval(3 * 3600)) == .disable(.timeUp))
        #expect(!lid.isOn)
        #expect(lid.handle(.tick, now: now.addingTimeInterval(4 * 3600)) == .none)
    }

    @Test func untilUnpluggedHasNoTimeLimit() {
        var lid = LidAwake()
        _ = lid.handle(.switchOn(.untilUnplugged, onPower: true, ruleInstalled: true), now: now)
        #expect(lid.until == nil)
        #expect(lid.remaining(now: now) == nil)
        #expect(lid.handle(.tick, now: now.addingTimeInterval(86_400)) == .none)
        #expect(lid.handle(.power(onPower: true), now: now) == .none)
        #expect(lid.handle(.power(onPower: false), now: now) == .disable(.unplugged))
        #expect(!lid.isOn)
    }

    @Test func anotherTimeWhileOnOnlyMovesTheEnd() {
        var lid = LidAwake()
        _ = lid.handle(.switchOn(.oneHour, onPower: true, ruleInstalled: true), now: now)
        let later = now.addingTimeInterval(600)
        #expect(lid.handle(.switchOn(.threeHours, onPower: true, ruleInstalled: true), now: later) == .none)
        #expect(lid.until == later.addingTimeInterval(3 * 3600))
    }

    @Test func offQuitAndFailure() {
        var lid = LidAwake()
        #expect(lid.handle(.switchOff, now: now) == .none)
        #expect(lid.handle(.quit, now: now) == .none)
        _ = lid.handle(.switchOn(.oneHour, onPower: true, ruleInstalled: true), now: now)
        #expect(lid.handle(.quit, now: now) == .disable(.quit))
        _ = lid.handle(.switchOn(.oneHour, onPower: true, ruleInstalled: true), now: now)
        #expect(lid.handle(.switchOff, now: now) == .disable(.user))
        _ = lid.handle(.switchOn(.oneHour, onPower: true, ruleInstalled: true), now: now)
        #expect(lid.handle(.failed, now: now) == .none)
        #expect(!lid.isOn)
        #expect(LidAwake.needsCleanup(markerExists: true))
        #expect(!LidAwake.needsCleanup(markerExists: false))
    }

    @Test func commandsAreExactlyTheTwoAllowed() {
        #expect(LidAwakeCommands.sudoArguments(true) == ["-n", "/usr/bin/pmset", "-a", "disablesleep", "1"])
        #expect(LidAwakeCommands.sudoArguments(false) == ["-n", "/usr/bin/pmset", "-a", "disablesleep", "0"])
        #expect(LidAwakeCommands.checkArguments == ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "1"])
        #expect(LidAwakeCommands.ruleFile == "/etc/sudoers.d/starnotch-pmset")
    }

    @Test func theRuleNamesOneUserAndTwoCommands() throws {
        let rule = try #require(LidAwakeCommands.sudoersRule(user: "nora.k"))
        let lines = rule.split(separator: "\n").filter { !$0.hasPrefix("#") }
        #expect(lines == ["nora.k ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0"])
        #expect(rule.hasSuffix("\n"))
        for bad in ["", "-x", "root ALL", "a,b", "me\nroot", "ü", "%admin", String(repeating: "a", count: 65)] {
            #expect(LidAwakeCommands.sudoersRule(user: bad) == nil)
        }
    }

    @Test func theInstallScriptChecksBeforeItMoves() throws {
        let script = try #require(LidAwakeCommands.installScript(user: "nora"))
        let check = try #require(script.range(of: "/usr/sbin/visudo -cf \"$tmp\""))
        let mode = try #require(script.range(of: "/bin/chmod 0440 \"$tmp\""))
        let owner = try #require(script.range(of: "/usr/sbin/chown root:wheel \"$tmp\""))
        let move = try #require(script.range(of: "/bin/mv -f \"$tmp\" '/etc/sudoers.d/starnotch-pmset'"))
        #expect(check.upperBound < owner.lowerBound && owner.upperBound < mode.lowerBound && mode.upperBound < move.lowerBound)
        #expect(script.contains("'nora ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0'"))
        #expect(!script.contains("\n"))
        #expect(LidAwakeCommands.installScript(user: "a b") == nil)
        #expect(LidAwakeCommands.removeScript() == "/bin/rm -f '/etc/sudoers.d/starnotch-pmset'")
    }

    @Test func appleScriptEscapesQuotesAndBackslashes() {
        let script = LidAwakeCommands.appleScript(shell: #"printf '%s\n' "$tmp""#, prompt: #"Say "yes""#)
        #expect(script == #"do shell script "printf '%s\\n' \"$tmp\"" with prompt "Say \"yes\"" with administrator privileges"#)
    }

    @Test func readsSleepDisabledFromPmset() {
        #expect(LidAwakeCommands.sleepDisabled(pmsetOutput: "System-wide power settings:\n SleepDisabled\t\t1\nCurrently in use:\n sleep 1") == true)
        #expect(LidAwakeCommands.sleepDisabled(pmsetOutput: " SleepDisabled\t\t0\n") == false)
        #expect(LidAwakeCommands.sleepDisabled(pmsetOutput: "Currently in use:\n sleep 1") == nil)
    }

    @Test func readsWhatOsascriptSaid() {
        #expect(LidAwakeCommands.adminFailure(status: 0, output: "") == nil)
        #expect(LidAwakeCommands.adminFailure(status: 1, output: "0:120: execution error: User canceled. (-128)\n") == "")
        #expect(LidAwakeCommands.adminFailure(status: 1, output: "0:12: execution error: visudo: syntax error (1)\n") == "visudo: syntax error")
        #expect(LidAwakeCommands.adminFailure(status: 1, output: "") == LidAwakeCommands.unknownFailure)
    }

    @Test func theLedgerKnowsIt() {
        #expect(SetupItem.lidAwake.isRemovable)
        #expect(SetupItem.lidAwake.title == "Keep awake with the lid closed")
    }
}
