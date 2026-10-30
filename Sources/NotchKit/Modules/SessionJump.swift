import AppKit
import NotchCore

/// Brings a session's own tab, pane or window to the front. What the session's process inherited
/// from its terminal (its environment: iTerm2's session id, WezTerm's pane, kitty's window, tmux's
/// pane) and its terminal device decide the way (`TerminalJump.plan`): Terminal and iTerm2 by
/// AppleScript (macOS asks once per terminal), WezTerm and kitty by their own command line, tmux
/// by selecting the pane, VS Code and Cursor by raising the window of the project. Whatever can't
/// be reached exactly (Ghostty, Warp) brings its app to the front.
@MainActor
enum SessionJump {
    /// True when something came to the front.
    static func open(_ agent: AgentSnapshot.Agent) -> Bool {
        guard let pid = agent.pid else { return false }
        let environment = Processes.arguments(of: pid, environmentKeys: TerminalJump.environmentKeys)?.environment ?? [:]
        var tty = agent.tty ?? Processes.tty(of: pid)
        var hostPID = pid
        var hostEnvironment = environment
        // Inside tmux: select the pane, then go on with the terminal that shows its session.
        if let tmux = tmuxBinary(), let client = selectTmuxPane(tmux, environment: environment, tty: tty, pid: pid) {
            hostPID = client.pid
            tty = client.tty
            hostEnvironment = Processes.arguments(of: client.pid, environmentKeys: TerminalJump.environmentKeys)?.environment ?? [:]
        }
        guard let app = AgentsModule.hostApp(of: hostPID) else { return false }
        let context = TerminalJump.Context(bundleID: app.bundleIdentifier ?? "", tty: tty, cwd: agent.cwd, environment: hostEnvironment)
        run(TerminalJump.plan(context), app: app)
        return true
    }

    /// Tries each step off the main thread, one jump at a time; the app comes to the front when
    /// none reached the tab (and after a command line tool, which focuses only inside its app).
    private static func run(_ steps: [JumpStep], app: NSRunningApplication) {
        queue.async {
            var reached = false
            var activate = false
            for step in steps {
                switch step {
                case .appleScript(let source):
                    reached = runScript(source)
                case .raiseWindow(let bundleID, let title):
                    // Without Accessibility, System Events would put up macOS's prompt on every jump.
                    guard AXIsProcessTrusted(), let source = TerminalJump.raiseScript(bundleID: bundleID, title: title) else { continue }
                    reached = runScript(source)
                case .command(let candidates, let arguments, let environment):
                    guard let tool = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { continue }
                    reached = SetupActions.processRunner(tool, arguments, environment).status == 0
                    activate = reached
                case .activate:
                    activate = true
                }
                if reached { break }
            }
            if activate || !reached { DispatchQueue.main.async { app.activate() } }
        }
    }

    private static let queue = DispatchQueue(label: "session-jump", qos: .userInitiated)

    /// True when the script returned true. The first run waits for macOS's permission prompt.
    private nonisolated static func runScript(_ source: String) -> Bool {
        var error: NSDictionary?
        return NSAppleScript(source: source)?.executeAndReturnError(&error).booleanValue == true
    }

    // MARK: tmux

    /// Selects the session's tmux pane (from `TMUX`/`TMUX_PANE`, else by its terminal device) and
    /// returns the client that shows it: the terminal to bring forward instead.
    private static func selectTmuxPane(_ tmux: String, environment: [String: String], tty: String?, pid: Int32) -> (pid: Int32, tty: String)? {
        var server: [String] = []
        var target: String?
        if let pane = TerminalJump.tmuxPane(environment: environment) {
            server = ["-S", pane.socket]
            target = pane.pane
        } else if let tty, isInsideTmux(pid) {
            target = TerminalJump.tmuxTarget(panes: run(tmux, ["list-panes", "-a", "-F", "#{pane_tty} #{session_name}:#{window_index}.#{pane_index}"]), tty: tty)
        }
        guard let target else { return nil }
        _ = run(tmux, server + ["select-window", "-t", target])
        _ = run(tmux, server + ["select-pane", "-t", target])
        let session = run(tmux, server + ["display-message", "-p", "-t", target, "#{session_name}"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !session.isEmpty else { return nil }
        return TerminalJump.tmuxClient(clients: run(tmux, server + ["list-clients", "-F", "#{client_pid} #{client_tty} #{session_name}"]), session: session)
    }

    private static func isInsideTmux(_ pid: Int32) -> Bool {
        var current: Int32? = pid
        for _ in 0..<12 {
            guard let p = current else { return false }
            if Processes.executable(of: p).map({ ($0 as NSString).lastPathComponent }) == "tmux" { return true }
            current = Processes.parent(of: p)
        }
        return false
    }

    private static func tmuxBinary() -> String? {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func run(_ tool: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
