import AppKit
import NotchCore

/// Brings a session's own terminal tab or pane to the front: Terminal and iTerm2 by AppleScript
/// (macOS asks once per terminal for permission, on the first click), tmux by selecting the pane,
/// otherwise the hosting app (VS Code, Ghostty).
@MainActor
enum SessionJump {
    /// True when something came to the front.
    static func open(_ agent: AgentSnapshot.Agent) -> Bool {
        guard let pid = agent.pid else { return false }
        let tty = agent.tty ?? Processes.tty(of: pid)
        // Inside tmux: select the pane, then jump to the terminal that shows that tmux session.
        if let tty, let tmux = tmuxBinary(), isInsideTmux(pid) {
            if let target = TerminalJump.tmuxTarget(panes: run(tmux, ["list-panes", "-a", "-F", "#{pane_tty} #{session_name}:#{window_index}.#{pane_index}"]), tty: tty) {
                let session = String(target.split(separator: ":").first ?? "")
                _ = run(tmux, ["select-window", "-t", target])
                _ = run(tmux, ["select-pane", "-t", target])
                if let client = TerminalJump.tmuxClient(clients: run(tmux, ["list-clients", "-F", "#{client_pid} #{client_tty} #{session_name}"]), session: session),
                   let app = AgentsModule.hostApp(of: client.pid) {
                    focus(app, tty: client.tty)
                    return true
                }
            }
        }
        guard let app = AgentsModule.hostApp(of: pid) else { return false }
        focus(app, tty: tty)
        return true
    }

    private static func focus(_ app: NSRunningApplication, tty: String?) {
        let bundle = app.bundleIdentifier ?? ""
        if let tty, let source = TerminalJump.script(bundleID: bundle, tty: tty) {
            // Off the main thread (the first run waits for the answer to macOS's permission
            // prompt), one script at a time.
            scripts.async {
                var error: NSDictionary?
                let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
                if result?.booleanValue != true {
                    DispatchQueue.main.async { app.activate() }
                }
            }
            return
        }
        // VS Code, Ghostty and others: the app. VS Code's terminal panel can't be addressed from
        // outside without an extension, and opening the folder could open a second window.
        app.activate()
    }

    private static let scripts = DispatchQueue(label: "session-jump.applescript", qos: .userInitiated)

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
