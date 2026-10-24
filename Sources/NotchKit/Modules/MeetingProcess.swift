import Darwin
import Foundation

/// A command run through a login shell in its own process group, so one signal ends the shell,
/// `uv` and Python together. A GUI app has no shell environment: `zsh -lic` reads `~/.zshrc`,
/// which puts `uv` on the PATH and sets the API keys. stdout arrives line by line; stderr goes
/// to a log file.
final class MeetingProcess: @unchecked Sendable {
    let pid: pid_t
    private let input: FileHandle
    /// Kept here: a handle that's freed closes its descriptor, and the child gets a broken pipe.
    private let output: FileHandle
    private let lock = NSLock()
    private var inputOpen = true

    /// - Parameters:
    ///   - onLine: each stdout line, on a background queue.
    ///   - onExit: stdout closed (the process ended), on a background queue.
    init?(command: String, directory: URL, log: URL,
          onLine: @escaping @Sendable (Data) -> Void, onExit: @escaping @Sendable () -> Void) {
        // A write to a process that already ended must not kill the app.
        signal(SIGPIPE, SIG_IGN)
        let stdin = Pipe(), stdout = Pipe()
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, stdin.fileHandleForReading.fileDescriptor, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout.fileHandleForWriting.fileDescriptor, 1)
        posix_spawn_file_actions_addopen(&actions, 2, log.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        posix_spawn_file_actions_addchdir_np(&actions, directory.path)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Own process group; every other descriptor of the app stays closed in the child.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)

        let arguments = ["/bin/zsh", "-lic", command]
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, "/bin/zsh", &actions, &attributes, &argv, environ)
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        guard result == 0 else {
            try? stdin.fileHandleForWriting.close()
            try? stdout.fileHandleForReading.close()
            return nil
        }
        self.pid = pid
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading

        let buffer = LineBuffer()
        output.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                try? handle.close()
                buffer.flush().forEach(onLine)
                onExit()
            } else {
                buffer.append(data).forEach(onLine)
            }
        }
        // Reap the shell so it doesn't linger as a zombie.
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
    }

    func write(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard inputOpen else { return }
        try? input.write(contentsOf: data)
    }

    /// The agent ends when its stdin closes, after answering what it already read.
    func closeInput() {
        lock.lock()
        defer { lock.unlock() }
        guard inputOpen else { return }
        inputOpen = false
        try? input.close()
    }

    /// SIGTERM to the whole group: the shell, `uv` and Python.
    func terminate() {
        closeInput()
        kill(-pid, SIGTERM)
    }
}

/// Splits a byte stream into lines; only touched from one readability handler at a time.
private final class LineBuffer: @unchecked Sendable {
    private var pending = Data()

    func append(_ data: Data) -> [Data] {
        pending.append(data)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            lines.append(Data(pending[pending.startIndex..<newline]))
            pending = pending[pending.index(after: newline)...]
        }
        pending = Data(pending)
        return lines
    }

    func flush() -> [Data] {
        defer { pending = Data() }
        return pending.isEmpty ? [] : [pending]
    }
}
