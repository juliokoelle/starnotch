import Foundation

/// A helper process that prints one line per event (the MediaRemote helper): hands over each
/// complete line, then its exit status once, after the last line, all on `queue`. Its stdin stays
/// open while it runs, so a helper that watches stdin ends when the app goes away.
public final class LineProcess: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var buffer = Data()

    public init(executable: URL, arguments: [String]) {
        process.executableURL = executable
        process.arguments = arguments
    }

    /// Starts the process; throws when it can't run at all.
    public func start(queue: DispatchQueue, onLine: @escaping @Sendable (Data) -> Void,
                      onExit: @escaping @Sendable (Int32) -> Void) throws {
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // The exit comes after the last line: both the end of the output and the termination.
        let done = DispatchGroup()
        done.enter()
        done.enter()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                // End of output: the handler would otherwise fire again and again with nothing.
                handle.readabilityHandler = nil
                for line in self?.rest() ?? [] { queue.async { onLine(line) } }
                done.leave()
                return
            }
            for line in self?.append(data) ?? [] { queue.async { onLine(line) } }
        }
        process.terminationHandler = { _ in done.leave() }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            throw error
        }
        let process = process
        done.notify(queue: queue) { onExit(process.terminationStatus) }
    }

    /// Closes the helper's stdin and terminates it; the exit still arrives.
    public func stop() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    private func append(_ data: Data) -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        return Self.split(&buffer)
    }

    /// At the end: a last line without its newline.
    private func rest() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        let line = buffer
        buffer.removeAll()
        return line.isEmpty ? [] : [line]
    }

    /// The complete lines in `buffer`, without their newline; the rest stays.
    static func split(_ buffer: inout Data) -> [Data] {
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(Data(buffer[buffer.startIndex..<newline]))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        return lines
    }
}

/// When a helper that streams lines comes back after it ended: a run that lasted counts as one
/// failure, a run that ended soon after it started adds one, even if it printed lines first; after
/// three the helper stays off.
public struct HelperRestarts: Equatable, Sendable {
    public static let maxFailures = 3
    /// Shorter than this, a run counts as failing.
    public static let healthyRun: TimeInterval = 30

    public private(set) var failures = 0

    public init() {}

    public var gaveUp: Bool { failures >= Self.maxFailures }

    /// A run ended after `duration` seconds: true when the helper should start again.
    public mutating func ended(after duration: TimeInterval) -> Bool {
        failures = duration >= Self.healthyRun ? 1 : failures + 1
        return !gaveUp
    }

    /// The process couldn't run at all.
    public mutating func failedToStart() {
        failures = Self.maxFailures
    }
}
