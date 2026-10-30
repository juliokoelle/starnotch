import Foundation

// What Starnotch itself costs the Mac, without the system calls (NotchKit reads the counters): CPU and
// wake-ups from two readings of a process's counters, and the at-rest record, a reading every few minutes
// for the last 24 hours.

public enum AppCost {
    /// A process's counters as `proc_pid_rusage` gives them, CPU time already in nanoseconds.
    public struct Counters: Equatable, Sendable {
        /// When the process started (`ri_proc_start_abstime`): a pid used again belongs to another process.
        public var start: UInt64
        public var cpuNanoseconds: UInt64
        /// Package-idle plus interrupt wake-ups: what keeps the CPU from resting, the battery's best proxy.
        public var wakeups: UInt64
        /// Memory as Activity Monitor counts it (`ri_phys_footprint`).
        public var footprint: UInt64

        public init(start: UInt64, cpuNanoseconds: UInt64, wakeups: UInt64, footprint: UInt64) {
            self.start = start
            self.cpuNanoseconds = cpuNanoseconds
            self.wakeups = wakeups
            self.footprint = footprint
        }
    }

    /// Between two readings: the share of one core (1 = a whole core, as Activity Monitor's 100 %) and
    /// wake-ups per second.
    public struct Rate: Equatable, Sendable {
        public var cpu: Double
        public var wakeupsPerSecond: Double

        public init(cpu: Double, wakeupsPerSecond: Double) {
            self.cpu = cpu
            self.wakeupsPerSecond = wakeupsPerSecond
        }

        public static let zero = Rate(cpu: 0, wakeupsPerSecond: 0)
    }

    /// Nil without an earlier reading of the same process (a new pid, a reused one, counters that went back):
    /// its first reading says nothing about the last seconds.
    public static func rate(from old: Counters?, to new: Counters, seconds: Double) -> Rate? {
        guard let old, old.start == new.start, seconds > 0,
              new.cpuNanoseconds >= old.cpuNanoseconds, new.wakeups >= old.wakeups else { return nil }
        return Rate(cpu: Double(new.cpuNanoseconds - old.cpuNanoseconds) / 1e9 / seconds,
                    wakeupsPerSecond: Double(new.wakeups - old.wakeups) / seconds)
    }
}

/// Starnotch's own CPU share between readings a few minutes apart, the last 24 hours, in memory only.
public struct RestLog: Equatable, Sendable {
    public struct Point: Equatable, Sendable {
        public var time: Date
        /// The share of one core over the minutes before `time`.
        public var cpu: Double

        public init(time: Date, cpu: Double) {
            self.time = time
            self.cpu = cpu
        }
    }

    private struct Reading: Equatable, Sendable {
        var time: Date
        var cpuNanoseconds: UInt64
    }

    public static let window: TimeInterval = 24 * 3600
    /// Readings further apart than this span a sleep (CPU time stands still then): no point, a new start.
    public static let longestGap: TimeInterval = 15 * 60

    /// Oldest first.
    public private(set) var points: [Point]
    private var last: Reading?

    public init(points: [Point] = []) {
        self.points = points
    }

    /// The process's total CPU time now: the share since the reading before becomes a point.
    public mutating func record(cpuNanoseconds: UInt64, at time: Date) {
        if let last, cpuNanoseconds >= last.cpuNanoseconds {
            let seconds = time.timeIntervalSince(last.time)
            if seconds > 0, seconds <= Self.longestGap {
                points.append(Point(time: time, cpu: Double(cpuNanoseconds - last.cpuNanoseconds) / 1e9 / seconds))
            }
        }
        last = Reading(time: time, cpuNanoseconds: cpuNanoseconds)
        points.removeAll { time.timeIntervalSince($0.time) > Self.window }
    }

    /// The mean of the points since `start`; nil when there are none yet.
    public func average(since start: Date) -> Double? {
        let recent = points.filter { $0.time >= start }
        return recent.isEmpty ? nil : recent.reduce(0) { $0 + $1.cpu } / Double(recent.count)
    }
}
