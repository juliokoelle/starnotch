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
