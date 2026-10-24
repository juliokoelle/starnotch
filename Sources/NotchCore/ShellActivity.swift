import Foundation

/// Long terminal commands, from a small zsh snippet the user adds through the setup page. The
/// snippet writes one file per shell (`run-<pid>`: start, folder, command) while a command runs,
/// empties it when the prompt returns, and leaves `done-<pid>-<end>` for commands that took 30 s
/// or more. Only zsh builtins run on every prompt (no extra processes). The folder is 0700.
public enum ShellActivity {
    public struct Running: Equatable, Sendable {
        public var pid: Int32
        public var start: Date
        public var cwd: String
        public var command: String

        public init(pid: Int32, start: Date, cwd: String, command: String) {
            self.pid = pid
            self.start = start
            self.cwd = cwd
            self.command = command
        }
    }

    public struct Finished: Equatable, Sendable {
        public var end: Date
        public var seconds: Int
        public var exitCode: Int32
        public var cwd: String
        public var command: String

        public var succeeded: Bool { exitCode == 0 }
    }

    public static let threshold = 30

    public static func snippet(folder: String) -> String {
        """
        # Starnotch: long terminal commands in the notch (loaded from ~/.zshrc by the setup page;
        # remove it in Settings › What's set up). Only builtins run on every prompt.
        zmodload zsh/datetime 2>/dev/null || return 0
        typeset -g __starnotch_dir=\(SetupActions.shellQuote(folder))
        __starnotch_preexec() {
          typeset -g __starnotch_start=$EPOCHSECONDS
          print -r -- "$EPOCHSECONDS"$'\\n'"$PWD"$'\\n'"${${1//$'\\n'/ }[1,80]}" >| "$__starnotch_dir/run-$$" 2>/dev/null
        }
        __starnotch_precmd() {
          local code=$?
          [[ -n $__starnotch_start ]] || return 0
          local took=$(( EPOCHSECONDS - __starnotch_start ))
          local run="$__starnotch_dir/run-$$"
          if (( took >= \(threshold) )) && [[ -s $run ]]; then
            local -a lines; lines=("${(@f)$(<$run)}")
            print -r -- "$EPOCHSECONDS $took $code"$'\\n'"${lines[2]}"$'\\n'"${lines[3]}" >| "$__starnotch_dir/done-$$-$EPOCHSECONDS" 2>/dev/null
          fi
          : >| $run 2>/dev/null
          unset __starnotch_start
        }
        autoload -Uz add-zsh-hook
        add-zsh-hook preexec __starnotch_preexec
        add-zsh-hook precmd __starnotch_precmd

        """
    }

    /// `run-<pid>`: start, folder, command; empty while the shell waits at its prompt.
    public static func running(file name: String, text: String) -> Running? {
        guard name.hasPrefix("run-"), let pid = Int32(name.dropFirst(4)) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 3, let start = Double(lines[0]), !lines[2].isEmpty else { return nil }
        return Running(pid: pid, start: Date(timeIntervalSince1970: start), cwd: lines[1], command: lines[2])
    }

    /// `done-<pid>-<end>`: "end seconds exit", folder, command.
    public static func finished(text: String) -> Finished? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 3 else { return nil }
        let head = lines[0].split(separator: " ")
        guard head.count == 3, let end = Double(head[0]), let seconds = Int(head[1]), let code = Int32(head[2]) else { return nil }
        return Finished(end: Date(timeIntervalSince1970: end), seconds: seconds, exitCode: code, cwd: lines[1], command: lines[2])
    }

    /// "npm run build finished · 2 m 14 s", "make test failed · exit 2 · 41 s".
    public static func line(_ done: Finished) -> String {
        let took = done.seconds >= 60 ? "\(done.seconds / 60) m \(done.seconds % 60) s" : "\(done.seconds) s"
        return done.succeeded ? "finished · \(took)" : "failed · exit \(done.exitCode) · \(took)"
    }
}
