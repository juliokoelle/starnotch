import Testing
import TestSupport
@testable import NotchCore

/// The exact jump: per terminal, the most exact way to a session's tab, from what its process inherited.
@Suite struct ExactJumpTests {
    @Test func iTermBySessionIdThenByTerminal() {
        let steps = TerminalJump.plan(.init(bundleID: TerminalJump.iTerm, tty: "/dev/ttys004", cwd: "/tmp",
                                            environment: ["ITERM_SESSION_ID": "w0t1p0:5B2C1F0E-0000-4000-8000-000000000001"]))
        #expect(steps.count == 3)
        guard case .appleScript(let first) = steps[0], case .appleScript(let second) = steps[1] else { Issue.record("not scripts"); return }
        #expect(first.contains("unique id of s is \"5B2C1F0E-0000-4000-8000-000000000001\""))
        #expect(second.contains("tty of s is \"/dev/ttys004\""))
        #expect(steps.last == .activate)
        // A forged id never reaches a script.
        let forged = TerminalJump.plan(.init(bundleID: TerminalJump.iTerm, tty: nil, cwd: nil,
                                             environment: ["ITERM_SESSION_ID": "w0t1p0:x\" & do shell script \"y"]))
        #expect(forged == [.activate])
    }

    @Test func weztermAndKittyByTheirCommandLine() {
        let wez = TerminalJump.plan(.init(bundleID: TerminalJump.wezterm, tty: nil, cwd: nil,
                                          environment: ["WEZTERM_PANE": "12", "WEZTERM_UNIX_SOCKET": "/tmp/wez.sock"]))
        guard case .command(_, let arguments, let environment) = wez[0] else { Issue.record("no command"); return }
        #expect(arguments == ["cli", "activate-pane", "--pane-id", "12"])
        #expect(environment == ["WEZTERM_UNIX_SOCKET": "/tmp/wez.sock"])
        let kitty = TerminalJump.plan(.init(bundleID: TerminalJump.kitty, tty: nil, cwd: nil,
                                            environment: ["KITTY_WINDOW_ID": "3", "KITTY_LISTEN_ON": "unix:/tmp/kitty"]))
        guard case .command(_, let kittyArguments, _) = kitty[0] else { Issue.record("no command"); return }
        #expect(kittyArguments == ["@", "--to", "unix:/tmp/kitty", "focus-window", "--match", "id:3"])
        // Without remote control: the app.
        #expect(TerminalJump.plan(.init(bundleID: TerminalJump.kitty, tty: nil, cwd: nil, environment: ["KITTY_WINDOW_ID": "3"])) == [.activate])
    }

    @Test func editorsByTheirProjectWindowOthersByTheApp() {
        let steps = TerminalJump.plan(.init(bundleID: "com.microsoft.VSCode", tty: "/dev/ttys009", cwd: "/tmp/no-repo-here/harbor"))
        #expect(steps == [.raiseWindow(bundleID: "com.microsoft.VSCode", titleContains: "harbor"), .activate])
        #expect(TerminalJump.raiseScript(bundleID: "com.microsoft.VSCode", title: "harbor")?.contains("name of w contains \"harbor\"") == true)
        #expect(TerminalJump.raiseScript(bundleID: "com.microsoft.VSCode", title: "a\"b") == nil)
        #expect(TerminalJump.plan(.init(bundleID: TerminalJump.ghostty, tty: "/dev/ttys001", cwd: "/tmp")) == [.activate])
        #expect(TerminalJump.plan(.init(bundleID: TerminalJump.warp, tty: "/dev/ttys001", cwd: "/tmp")) == [.activate])
    }

    @Test func tmuxPaneFromTheEnvironment() {
        let pane = TerminalJump.tmuxPane(environment: ["TMUX": "/private/tmp/tmux-501/default,4242,0", "TMUX_PANE": "%12"])
        #expect(pane?.socket == "/private/tmp/tmux-501/default")
        #expect(pane?.pane == "%12")
        #expect(TerminalJump.tmuxPane(environment: ["TMUX": "/tmp/s,1,0", "TMUX_PANE": "%1; rm"]) == nil)
        #expect(TerminalJump.tmuxPane(environment: [:]) == nil)
    }

    @Test func processArgumentsAndEnvironment() throws {
        let bytes = ProcArgsSample.bytes(arguments: ["node", "/usr/local/lib/gemini-cli/bundle/gemini.js"],
                                         environment: ["TERM_PROGRAM=WezTerm", "WEZTERM_PANE=7", "EMPTY=", "A=b=c"])
        let parsed = try #require(Processes.parseProcArgs(bytes))
        #expect(parsed.arguments == ["node", "/usr/local/lib/gemini-cli/bundle/gemini.js"])
        #expect(parsed.environment["WEZTERM_PANE"] == "7")
        #expect(parsed.environment["EMPTY"] == "")
        #expect(parsed.environment["A"] == "b=c")
        #expect(Processes.parseProcArgs([1, 0]) == nil)
    }

    @Test func aScanReadsOnlyWhatItNeeds() throws {
        let bytes = ProcArgsSample.bytes(arguments: ["node", "/opt/copilot/index.js", "--yolo", "fix it"],
                                         environment: ["WEZTERM_PANE=7", "SECRET_TOKEN=abc"])
        // The process scan: the first arguments, no environment.
        let leading = try #require(Processes.parseProcArgs(bytes[...], maxArguments: 3))
        #expect(leading.arguments == ["node", "/opt/copilot/index.js", "--yolo"])
        #expect(leading.environment.isEmpty)
        // A jump: only the terminal's variables.
        let jump = try #require(Processes.parseProcArgs(bytes[...], environmentKeys: TerminalJump.environmentKeys))
        #expect(jump.environment == ["WEZTERM_PANE": "7"])
    }
}
