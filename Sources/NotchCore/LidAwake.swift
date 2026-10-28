import Foundation

// "Keep awake with the lid closed": macOS allows it only through `pmset -a disablesleep 1`, which
// needs root. The setup installs one sudoers rule for exactly the two pmset commands (macOS asks
// for the password once); after that the switch runs them through `sudo -n`, which never prompts.
// It runs on the power adapter and on battery. It ends after the chosen time, on battery when the
// charge reaches the floor, and when the Mac gets too hot; plugging in or out changes nothing.
// Starnotch switches it off when it quits or, after a crash, at the next launch (a marker in the
// support folder says that Starnotch was the one who switched it on).

/// How long the Mac stays awake with the lid closed.
public enum LidAwakeLimit: String, CaseIterable, Codable, Sendable {
    case oneHour, threeHours, untilOff

    /// Nil: until the user switches it off (the battery floor and the heat still end it).
    public var duration: TimeInterval? {
        switch self {
        case .oneHour: 3600
        case .threeHours: 3 * 3600
        case .untilOff: nil
        }
    }
}

/// What the Mac says right now, for the safety checks.
public struct LidAwakeReadings: Equatable, Sendable {
    /// The charge in percent while on battery; nil on the power adapter (or without a battery).
    public var batteryPercent: Int?
    public var thermal: ProcessInfo.ThermalState

    public init(batteryPercent: Int?, thermal: ProcessInfo.ThermalState) {
        self.batteryPercent = batteryPercent
        self.thermal = thermal
    }

    /// From the power source as IOKit reports it: the floor counts only off the power adapter.
    public init(battery: BatteryState?, thermal: ProcessInfo.ThermalState) {
        self.init(batteryPercent: battery.flatMap { $0.pluggedIn ? nil : $0.percent }, thermal: thermal)
    }

    /// `.serious` and `.critical`: macOS already slows the Mac down to cool it.
    public var tooHot: Bool { thermal == .serious || thermal == .critical }
}

/// The switch as a state machine: every event goes through `handle`, which says what to run.
public struct LidAwake: Equatable, Sendable {
    /// The charges to stop at on battery, in percent.
    public static let floors = [10, 20, 30, 50]
    public static let defaultFloor = 20

    public enum State: Equatable, Sendable {
        case off
        /// `until` nil: until switched off.
        case on(since: Date, until: Date?)
    }

    public enum Event: Equatable, Sendable {
        /// The user picked a time and a floor. `ruleInstalled`: `sudo -n` may run pmset.
        case switchOn(LidAwakeLimit, floor: Int, readings: LidAwakeReadings, ruleInstalled: Bool)
        case switchOff
        /// A moment to look again: the timer fired, the power source or the heat changed.
        case check(LidAwakeReadings)
        case quit
        /// pmset didn't run: back to off without running anything.
        case failed
    }

    public enum Reason: String, Equatable, Sendable { case user, timeUp, batteryLow, tooHot, quit }

    public enum Action: Equatable, Sendable {
        case none
        /// Not switched on (`batteryLow` or `tooHot`): say why, change nothing.
        case refused(Reason)
        /// Ask for the password once and install the rule, then send `switchOn` again.
        case installRule
        /// Run `pmset -a disablesleep 1`, then write the marker.
        case enable
        /// Run `pmset -a disablesleep 0`, then remove the marker.
        case disable(Reason)
    }

    public private(set) var state: State = .off
    /// The charge it stops at on battery, set with each switch-on.
    public private(set) var floor = LidAwake.defaultFloor

    public init(state: State = .off, floor: Int = LidAwake.defaultFloor) {
        self.state = state
        self.floor = floor
    }

    public var isOn: Bool { state != .off }

    public var until: Date? {
        if case .on(_, let until) = state { return until }
        return nil
    }

    public mutating func handle(_ event: Event, now: Date) -> Action {
        switch event {
        case .switchOn(let limit, let floor, let readings, let ruleInstalled):
            if let reason = Self.refusal(floor: floor, readings) { return .refused(reason) }
            guard ruleInstalled else { return .installRule }
            let wasOn = isOn
            self.floor = floor
            state = .on(since: now, until: limit.duration.map { now.addingTimeInterval($0) })
            // Another time while on only moves the end; pmset already runs.
            return wasOn ? .none : .enable
        case .switchOff:
            return turnOff(.user)
        case .check(let readings):
            if let reason = Self.refusal(floor: floor, readings) { return turnOff(reason) }
            guard let until, now >= until else { return .none }
            return turnOff(.timeUp)
        case .quit:
            return turnOff(.quit)
        case .failed:
            state = .off
            return .none
        }
    }

    private mutating func turnOff(_ reason: Reason) -> Action {
        guard isOn else { return .none }
        state = .off
        return .disable(reason)
    }

    /// Why it may not run now, nil when it may: too hot first, then on battery a charge at or
    /// under the floor (switching on right at the floor would only end it at once).
    public static func refusal(floor: Int, _ readings: LidAwakeReadings) -> Reason? {
        if readings.tooHot { return .tooHot }
        if let percent = readings.batteryPercent, percent <= floor { return .batteryLow }
        return nil
    }

    /// Seconds until the limit, nil without one (or while off).
    public func remaining(now: Date) -> TimeInterval? { until.map { max(0, $0.timeIntervalSince(now)) } }

    /// At launch: a marker means Starnotch switched sleep off and didn't get to switch it back on
    /// (a crash, a forced quit, a power cut). Without one, sleep was changed by someone else: leave it.
    public static func needsCleanup(markerExists: Bool) -> Bool { markerExists }
}

/// The commands and texts, exactly as they run; all of it plain strings, so tests read them.
public enum LidAwakeCommands {
    public static let pmset = "/usr/bin/pmset"
    public static let sudo = "/usr/bin/sudo"
    public static let ruleFile = "/etc/sudoers.d/\(Brand.name.lowercased())-pmset"

    /// `-a disablesleep 1` or `0`: the only two commands the rule allows.
    public static func pmsetArguments(_ disableSleep: Bool) -> [String] { ["-a", "disablesleep", disableSleep ? "1" : "0"] }

    /// `sudo -n` fails at once instead of asking when the rule is missing.
    public static func sudoArguments(_ disableSleep: Bool) -> [String] { ["-n", pmset] + pmsetArguments(disableSleep) }

    /// Exits 0 only when the rule lets this user run pmset without a password.
    public static let checkArguments = ["-n", "-l", pmset] + pmsetArguments(true)

    /// macOS short names: letters, digits, `_`, `.` and `-`, not starting with `-`. Anything else
    /// would need escaping in sudoers, so the rule is never written for it.
    public static func isValidUser(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, !name.isEmpty, name.count <= 64, first != "-", first != "." else { return false }
        return name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || "_.-".unicodeScalars.contains($0) }
    }

    /// The whole rule file: this user, as root, these two commands with exactly these arguments.
    public static func sudoersRule(user: String) -> String? {
        guard isValidUser(user) else { return nil }
        let commands = [true, false].map { ([pmset] + pmsetArguments($0)).joined(separator: " ") }.joined(separator: ", ")
        return """
        # \(Brand.name): keep awake with the lid closed. Lets \(user) switch sleep off and on, nothing else.
        # Remove it in \(Brand.name) > Settings > What's set up, or delete this file.
        \(user) ALL=(root) NOPASSWD: \(commands)

        """
    }

    /// Runs as root (`do shell script … with administrator privileges`): writes the rule to a
    /// temporary file, lets visudo check it, sets owner root and mode 0440, and only then moves
    /// it in place. A rule visudo rejects never reaches /etc/sudoers.d.
    public static func installScript(user: String, file: String = ruleFile) -> String? {
        guard let rule = sudoersRule(user: user) else { return nil }
        let lines = rule.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map { SetupActions.shellQuote(String($0)) }
        let folder = (file as NSString).deletingLastPathComponent
        return [
            "tmp=$(/usr/bin/mktemp /tmp/\(Brand.name.lowercased())-pmset.XXXXXX) || exit 1",
            "trap '/bin/rm -f \"$tmp\"' EXIT",
            "/usr/bin/printf '%s\\n' \(lines.joined(separator: " ")) > \"$tmp\"",
            "/usr/sbin/visudo -cf \"$tmp\" >/dev/null",
            "/usr/sbin/chown root:wheel \"$tmp\"",
            "/bin/chmod 0440 \"$tmp\"",
            "/bin/mkdir -p \(SetupActions.shellQuote(folder))",
            "/bin/mv -f \"$tmp\" \(SetupActions.shellQuote(file))",
        ].joined(separator: " && ")
    }

    /// Runs as root: removes the rule, nothing else.
    public static func removeScript(file: String = ruleFile) -> String { "/bin/rm -f \(SetupActions.shellQuote(file))" }

    /// `do shell script "…" with prompt "…" with administrator privileges`, both strings escaped
    /// for AppleScript.
    public static func appleScript(shell: String, prompt: String) -> String {
        func literal(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return "do shell script \(literal(shell)) with prompt \(literal(prompt)) with administrator privileges"
    }

    /// Stands for "no message from osascript"; the app shows its own line for it.
    public static let unknownFailure = "?"

    /// What `osascript -e <appleScript>` said: nil when it ran, "" when the user cancelled the
    /// password dialog (error -128), the message otherwise (`unknownFailure` without one).
    public static func adminFailure(status: Int32, output: String) -> String? {
        guard status != 0 else { return nil }
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix("(-128)") { return "" }
        // "0:12: execution error: The administrator user name or password was incorrect. (-60007)"
        var message = text.range(of: "execution error: ").map { String(text[$0.upperBound...]) } ?? text
        if let code = message.range(of: #" \(-?\d+\)$"#, options: .regularExpression) { message.removeSubrange(code) }
        return message.isEmpty ? unknownFailure : message
    }

    /// `SleepDisabled` from `pmset -g`; nil when the line is missing.
    public static func sleepDisabled(pmsetOutput: String) -> Bool? {
        for line in pmsetOutput.split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace)
            if parts.count >= 2, parts[0] == "SleepDisabled" { return parts[1] == "1" }
        }
        return nil
    }
}
