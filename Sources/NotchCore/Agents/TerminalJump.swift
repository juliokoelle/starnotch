import Foundation

/// How to bring one terminal tab or pane to the front, by the terminal device of the session's
/// process. Pure text here (AppleScript sources, tmux targets); the app runs them on a click.
public enum TerminalJump {
    public static let terminal = "com.apple.Terminal"
    public static let iTerm = "com.googlecode.iterm2"

    /// Only "/dev/ttysNNN" goes into a script.
    public static func isSafe(tty: String) -> Bool {
        tty.wholeMatch(of: #/\/dev\/ttys[0-9]{1,4}/#) != nil
    }

    /// AppleScript that selects the tab (Terminal) or session (iTerm2) on `tty` and returns true;
    /// nil for terminals without a scripting interface for it.
    public static func script(bundleID: String, tty: String) -> String? {
        guard isSafe(tty: tty) else { return nil }
        switch bundleID {
        case terminal:
            return """
            tell application id "\(terminal)"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then
                            set selected tab of w to t
                            set index of w to 1
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end tell
            return false
            """
        case iTerm:
            return """
            tell application id "\(iTerm)"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(tty)" then
                                tell w to select
                                tell t to select
                                tell s to select
                                activate
                                return true
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return false
            """
        default:
            return nil
        }
    }

    /// The tmux pane on `tty` from `tmux list-panes -a -F "#{pane_tty} #{session_name}:#{window_index}.#{pane_index}"`.
    public static func tmuxTarget(panes: String, tty: String) -> String? {
        for line in panes.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2, parts[0] == tty { return String(parts[1]) }
        }
        return nil
    }

    /// The client attached to tmux session `session` from `tmux list-clients -F "#{client_pid} #{client_tty} #{session_name}"`.
    public static func tmuxClient(clients: String, session: String) -> (pid: Int32, tty: String)? {
        for line in clients.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
            if parts.count == 3, parts[2] == session, let pid = Int32(parts[0]) { return (pid, parts[1]) }
        }
        return nil
    }
}

// MARK: Exact jump per terminal

/// One way to bring a session's tab, pane or window to the front; the app tries them in order.
public enum JumpStep: Equatable, Sendable {
    /// AppleScript sent to the terminal itself (macOS asks once per terminal).
    case appleScript(String)
    /// The terminal's own command line tool (WezTerm, kitty): the first candidate that exists.
    case command(candidates: [String], arguments: [String], environment: [String: String])
    /// The editor window whose title names the project, through System Events (needs Accessibility).
    case raiseWindow(bundleID: String, titleContains: String)
    /// The app, as the last resort.
    case activate
}

extension TerminalJump {
    public static let ghostty = "com.mitchellh.ghostty"
    public static let warp = "dev.warp.Warp-Stable"
    public static let wezterm = "com.github.wez.wezterm"
    public static let kitty = "net.kovidgoyal.kitty"
    /// Editors whose integrated terminal hosts agents: VS Code (and Insiders, VSCodium), Cursor, Windsurf.
    public static let editors: Set<String> = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium",
                                              "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf"]

    /// The only variables of a process's environment a jump reads (no keys or tokens are kept).
    public static let environmentKeys: Set<String> = ["ITERM_SESSION_ID", "WEZTERM_PANE", "WEZTERM_UNIX_SOCKET", "KITTY_WINDOW_ID",
                                                      "KITTY_LISTEN_ON", "TMUX", "TMUX_PANE"]

    /// What the session's process tells about its terminal (its environment), the terminal's
    /// bundle id, the terminal device and the folder.
    public struct Context: Equatable, Sendable {
        public var bundleID: String
        public var tty: String?
        public var cwd: String?
        public var environment: [String: String]

        public init(bundleID: String, tty: String?, cwd: String?, environment: [String: String] = [:]) {
            self.bundleID = bundleID
            self.tty = tty
            self.cwd = cwd
            self.environment = environment
        }
    }

    /// The ways to the session's own tab, most exact first, always ending with the app.
    public static func plan(_ context: Context) -> [JumpStep] {
        var steps: [JumpStep] = []
        let env = context.environment
        switch context.bundleID {
        case iTerm:
            // ITERM_SESSION_ID is "w0t1p0:<uuid>"; the uuid is the session's unique id.
            if let id = env["ITERM_SESSION_ID"]?.split(separator: ":").last.map(String.init), isSafe(identifier: id) {
                steps.append(.appleScript(iTermScript(uniqueID: id)))
            }
            if let tty = context.tty, let source = script(bundleID: iTerm, tty: tty) { steps.append(.appleScript(source)) }
        case terminal:
            if let tty = context.tty, let source = script(bundleID: terminal, tty: tty) { steps.append(.appleScript(source)) }
        case wezterm:
            if let pane = env["WEZTERM_PANE"], pane.allSatisfy(\.isNumber), !pane.isEmpty {
                var environment: [String: String] = [:]
                if let socket = env["WEZTERM_UNIX_SOCKET"] { environment["WEZTERM_UNIX_SOCKET"] = socket }
                steps.append(.command(candidates: ["/Applications/WezTerm.app/Contents/MacOS/wezterm", "/opt/homebrew/bin/wezterm", "/usr/local/bin/wezterm"],
                                      arguments: ["cli", "activate-pane", "--pane-id", pane], environment: environment))
            }
        case kitty:
            // Needs remote control in kitty.conf (allow_remote_control, listen_on); otherwise the app.
            if let window = env["KITTY_WINDOW_ID"], window.allSatisfy(\.isNumber), !window.isEmpty, let listen = env["KITTY_LISTEN_ON"] {
                steps.append(.command(candidates: ["/Applications/kitty.app/Contents/MacOS/kitten", "/opt/homebrew/bin/kitten", "/usr/local/bin/kitten"],
                                      arguments: ["@", "--to", listen, "focus-window", "--match", "id:\(window)"], environment: [:]))
            }
        case let id where editors.contains(id):
            // The integrated terminal can't be addressed from outside; its window can, by the
            // workspace folder in its title.
            if let cwd = context.cwd {
                let name = ((ProjectPaths.projectRoot(of: cwd) ?? cwd) as NSString).lastPathComponent
                if isSafe(title: name) { steps.append(.raiseWindow(bundleID: id, titleContains: name)) }
            }
        default:
            // Ghostty, Warp and others have no way in from outside: the app.
            break
        }
        steps.append(.activate)
        return steps
    }

    /// iTerm2's session by its unique id.
    static func iTermScript(uniqueID: String) -> String {
        """
        tell application id "\(iTerm)"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if unique id of s is "\(uniqueID)" then
                            tell w to select
                            tell t to select
                            tell s to select
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return false
        """
    }

    /// System Events raises the app's first window whose title contains `title`.
    public static func raiseScript(bundleID: String, title: String) -> String? {
        guard isSafe(title: title), isSafe(identifier: bundleID) else { return nil }
        return """
        tell application "System Events"
            set targets to (every process whose bundle identifier is "\(bundleID)")
            if targets is {} then return false
            tell item 1 of targets
                repeat with w in windows
                    if name of w contains "\(title)" then
                        perform action "AXRaise" of w
                        set frontmost to true
                        return true
                    end if
                end repeat
            end tell
        end tell
        return false
        """
    }

    /// Only letters, digits, dots, dashes, underscores and spaces go into a script.
    static func isSafe(title: String) -> Bool {
        !title.isEmpty && title.count <= 120 && title.allSatisfy { $0.isLetter || $0.isNumber || " ._-".contains($0) }
    }

    static func isSafe(identifier: String) -> Bool {
        !identifier.isEmpty && identifier.count <= 80 && identifier.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-".contains($0)) }
    }

    /// The tmux server and pane of a process inside tmux, from its environment: `TMUX` is
    /// "<socket>,<pid>,<session>", `TMUX_PANE` is "%12".
    public static func tmuxPane(environment: [String: String]) -> (socket: String, pane: String)? {
        guard let tmux = environment["TMUX"], let socket = tmux.split(separator: ",").first.map(String.init), socket.hasPrefix("/"),
              let pane = environment["TMUX_PANE"], pane.wholeMatch(of: #/%[0-9]{1,6}/#) != nil else { return nil }
        return (socket, pane)
    }
}
