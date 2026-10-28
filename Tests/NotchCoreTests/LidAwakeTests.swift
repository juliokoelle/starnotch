import Foundation
import Testing
@testable import NotchCore

/// Keep awake with the lid closed: when pmset runs, when it stops, and the exact texts.
@Suite struct LidAwakeTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let onPower = LidAwakeReadings(batteryPercent: nil, thermal: .nominal)

    func battery(_ percent: Int, _ thermal: ProcessInfo.ThermalState = .nominal) -> LidAwakeReadings {
        LidAwakeReadings(batteryPercent: percent, thermal: thermal)
    }

    func on(_ limit: LidAwakeLimit = .oneHour, floor: Int = 20, _ readings: LidAwakeReadings? = nil) -> LidAwake.Event {
        .switchOn(limit, floor: floor, readings: readings ?? onPower, ruleInstalled: true)
    }

    @Test func onlyWithTheRule() {
        var lid = LidAwake()
        #expect(lid.handle(.switchOn(.oneHour, floor: 20, readings: onPower, ruleInstalled: false), now: now) == .installRule)
        #expect(!lid.isOn)
        #expect(lid.handle(on(), now: now) == .enable)
        #expect(lid.state == .on(since: now, until: now.addingTimeInterval(3600)))
    }

    @Test func switchesOnOnBattery() {
        var lid = LidAwake()
        #expect(lid.handle(on(.threeHours, floor: 20, battery(64)), now: now) == .enable)
        #expect(lid.state == .on(since: now, until: now.addingTimeInterval(3 * 3600)))
        #expect(lid.floor == 20)
    }

    @Test func refusedAtOrUnderTheFloorBeforeThePassword() {
        var lid = LidAwake()
        #expect(lid.handle(on(floor: 20, battery(19)), now: now) == .refused(.batteryLow))
        #expect(lid.handle(on(floor: 20, battery(20)), now: now) == .refused(.batteryLow))
        // Refused before the rule is asked for: no password for nothing.
        #expect(lid.handle(.switchOn(.oneHour, floor: 30, readings: battery(25), ruleInstalled: false), now: now) == .refused(.batteryLow))
        #expect(!lid.isOn)
        // The same charge on the power adapter, or with a lower floor, is fine.
        #expect(lid.handle(on(floor: 10, battery(19)), now: now) == .enable)
        var plugged = LidAwake()
        #expect(plugged.handle(on(floor: 50), now: now) == .enable)
    }

    @Test func refusedWhenTooHot() {
        for thermal in [ProcessInfo.ThermalState.serious, .critical] {
            var lid = LidAwake()
            #expect(lid.handle(on(.oneHour, LidAwakeReadings(batteryPercent: nil, thermal: thermal)), now: now) == .refused(.tooHot))
            // Too hot wins over a low battery.
            #expect(lid.handle(on(.oneHour, battery(5, thermal)), now: now) == .refused(.tooHot))
            #expect(!lid.isOn)
        }
        for thermal in [ProcessInfo.ThermalState.nominal, .fair] {
            var lid = LidAwake()
            #expect(lid.handle(on(.oneHour, battery(80, thermal)), now: now) == .enable)
        }
    }

    @Test func theFloorEndsItOnBattery() {
        var lid = LidAwake()
        _ = lid.handle(on(.untilOff, floor: 30, battery(70)), now: now)
        #expect(lid.handle(.check(battery(31)), now: now) == .none)
        #expect(lid.isOn)
        #expect(lid.handle(.check(battery(30)), now: now) == .disable(.batteryLow))
        #expect(!lid.isOn)
        #expect(lid.handle(.check(battery(29)), now: now) == .none)
    }

    @Test func theFloorCountsOnlyOffThePowerAdapter() {
        var lid = LidAwake()
        _ = lid.handle(on(.untilOff, floor: 50), now: now)
        // IOKit says 12 % but on power: no floor.
        let charging = LidAwakeReadings(battery: BatteryState(percent: 12, charging: true, pluggedIn: true, minutesLeft: nil), thermal: .nominal)
        #expect(charging.batteryPercent == nil)
        #expect(lid.handle(.check(charging), now: now) == .none)
        let unplugged = LidAwakeReadings(battery: BatteryState(percent: 12, charging: false, pluggedIn: false, minutesLeft: nil), thermal: .nominal)
        #expect(unplugged.batteryPercent == 12)
        #expect(lid.handle(.check(unplugged), now: now) == .disable(.batteryLow))
        #expect(LidAwakeReadings(battery: nil, thermal: .nominal).batteryPercent == nil)
    }

    @Test func heatEndsIt() {
        for thermal in [ProcessInfo.ThermalState.serious, .critical] {
            var lid = LidAwake()
            _ = lid.handle(on(.threeHours, battery(80)), now: now)
            #expect(lid.handle(.check(battery(80, .fair)), now: now) == .none)
            #expect(lid.handle(.check(battery(80, thermal)), now: now) == .disable(.tooHot))
            #expect(!lid.isOn)
            var plugged = LidAwake()
            _ = plugged.handle(on(.untilOff), now: now)
            #expect(plugged.handle(.check(LidAwakeReadings(batteryPercent: nil, thermal: thermal)), now: now) == .disable(.tooHot))
        }
    }

    @Test func pluggingInOrOutChangesNothing() {
        var lid = LidAwake()
        _ = lid.handle(on(.untilOff, floor: 20), now: now)
        #expect(lid.handle(.check(battery(90)), now: now) == .none)          // unplugged
        #expect(lid.handle(.check(onPower), now: now) == .none)              // plugged in again
        #expect(lid.handle(.check(battery(88)), now: now) == .none)          // and out
        #expect(lid.state == .on(since: now, until: nil))
        var started = LidAwake()
        _ = started.handle(on(.oneHour, floor: 20, battery(60)), now: now)
        #expect(started.handle(.check(onPower), now: now) == .none)
        #expect(started.isOn)
    }

    @Test func theLimitEndsIt() {
        var lid = LidAwake()
        _ = lid.handle(on(.threeHours), now: now)
        #expect(lid.handle(.check(onPower), now: now.addingTimeInterval(3 * 3600 - 1)) == .none)
        #expect(lid.remaining(now: now.addingTimeInterval(3600)) == 2 * 3600.0)  // a Double: an Int literal compares as AnyHashable and fails
        #expect(lid.handle(.check(onPower), now: now.addingTimeInterval(3 * 3600)) == .disable(.timeUp))
        #expect(!lid.isOn)
        #expect(lid.handle(.check(onPower), now: now.addingTimeInterval(4 * 3600)) == .none)
        var hour = LidAwake()
        _ = hour.handle(on(.oneHour, battery(90)), now: now)
        #expect(hour.handle(.check(battery(85)), now: now.addingTimeInterval(3600)) == .disable(.timeUp))
    }

    @Test func untilOffHasNoTimeLimit() {
        var lid = LidAwake()
        _ = lid.handle(on(.untilOff, battery(90)), now: now)
        #expect(LidAwakeLimit.untilOff.duration == nil)
        #expect(lid.until == nil)
        #expect(lid.remaining(now: now) == nil)
        #expect(lid.handle(.check(battery(80)), now: now.addingTimeInterval(86_400)) == .none)
        #expect(lid.handle(.switchOff, now: now) == .disable(.user))
        #expect(!lid.isOn)
    }

    @Test func anotherTimeWhileOnOnlyMovesTheEnd() {
        var lid = LidAwake()
        _ = lid.handle(on(.oneHour), now: now)
        let later = now.addingTimeInterval(600)
        #expect(lid.handle(on(.threeHours, floor: 30), now: later) == .none)
        #expect(lid.until == later.addingTimeInterval(3 * 3600))
        #expect(lid.floor == 30)
    }

    @Test func offQuitAndFailure() {
        var lid = LidAwake()
        #expect(lid.handle(.switchOff, now: now) == .none)
        #expect(lid.handle(.quit, now: now) == .none)
        #expect(lid.handle(.check(battery(5, .critical)), now: now) == .none)
        _ = lid.handle(on(), now: now)
        #expect(lid.handle(.quit, now: now) == .disable(.quit))
        _ = lid.handle(on(), now: now)
        #expect(lid.handle(.switchOff, now: now) == .disable(.user))
        _ = lid.handle(on(), now: now)
        #expect(lid.handle(.failed, now: now) == .none)
        #expect(!lid.isOn)
        #expect(LidAwake.needsCleanup(markerExists: true))
        #expect(!LidAwake.needsCleanup(markerExists: false))
    }

    @Test func theFloorsToPickFrom() {
        #expect(LidAwake.floors == [10, 20, 30, 50])
        #expect(LidAwake.defaultFloor == 20)
        #expect(LidAwake().floor == 20)
        #expect(LidAwakeLimit.allCases == [.oneHour, .threeHours, .untilOff])
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
