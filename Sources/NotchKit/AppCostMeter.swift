import Darwin
import Foundation
import NotchCore

/// What Starnotch costs this Mac, read with `proc_pid_rusage`: no helper, no permission (only our own
/// processes). In the background one reading of the app's own CPU time every 5 minutes (the at-rest record);
/// the Usage page samples the app and its child processes every 2 s, only while it is on screen.
@MainActor
final class AppCostMeter {
    static let shared = AppCostMeter()

    /// The last 24 hours of the app's own CPU, a point every 5 minutes.
    private(set) var rest = RestLog()
    private var task: Task<Void, Never>?

    /// One system call every 5 minutes, with a minute's leeway so the wake-up can share one with others.
    func start() {
        guard task == nil else { return }
        record()
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300), tolerance: .seconds(60))
                self?.record()
            }
        }
    }

    private func record() {
        guard let own = Self.counters(getpid()) else { return }
        rest.record(cpuNanoseconds: own.cpuNanoseconds, at: Date())
    }

    // MARK: Live

    /// A row of the Usage page: one process, or several of the same kind added up.
    struct Row: Identifiable, Equatable {
        var name: String
        var processes = 1
        /// Nil until a second reading.
        var rate: AppCost.Rate?
        var footprint: UInt64
        var id: String { name }
    }

    /// Readings 2 s apart for the page; keeps only the last reading of each pid.
    final class Live {
        private var last: [pid_t: AppCost.Counters] = [:]
        private var lastDate: Date?

        /// The app first, then its child processes by kind, the busiest first.
        func sample(now: Date = Date()) -> [Row] {
            let seconds = lastDate.map { now.timeIntervalSince($0) } ?? 0
            let me = getpid()
            var readings: [pid_t: AppCost.Counters] = [:]
            var rows: [Row] = []
            for pid in [me] + AppCostMeter.descendants(of: me) {
                guard let counters = AppCostMeter.counters(pid) else { continue }
                readings[pid] = counters
                let rate = AppCost.rate(from: last[pid], to: counters, seconds: seconds)
                let name = pid == me ? Brand.displayName : AppCostMeter.kind(of: pid)
                if let index = rows.firstIndex(where: { $0.name == name }) {
                    rows[index].processes += 1
                    rows[index].footprint += counters.footprint
                    // A process seen for the first time adds nothing yet to a row that has a rate.
                    if let rate { rows[index].rate = AppCost.Rate(cpu: (rows[index].rate?.cpu ?? 0) + rate.cpu,
                                                                  wakeupsPerSecond: (rows[index].rate?.wakeupsPerSecond ?? 0) + rate.wakeupsPerSecond) }
                } else {
                    rows.append(Row(name: name, rate: rate, footprint: counters.footprint))
                }
            }
            last = readings
            lastDate = now
            return [rows[0]] + rows.dropFirst().sorted { ($0.rate?.cpu ?? 0, $0.footprint) > ($1.rate?.cpu ?? 0, $1.footprint) }
        }
    }

    // MARK: System calls

    nonisolated static func counters(_ pid: pid_t) -> AppCost.Counters? {
        var usage = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard ok == 0 else { return nil }
        // CPU times are in Mach time units (not nanoseconds on Apple silicon).
        let cpu = (usage.ri_user_time + usage.ri_system_time) * timebase.numer / timebase.denom
        return AppCost.Counters(start: usage.ri_proc_start_abstime, cpuNanoseconds: cpu,
                                wakeups: usage.ri_pkg_idle_wkups + usage.ri_interrupt_wkups, footprint: usage.ri_phys_footprint)
    }

    nonisolated private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(1, info.denom)))
    }()

    /// Children, grandchildren and so on: Tara's agent runs as `uv`, which starts `python`, which starts
    /// `claude` or `codex` while she thinks.
    nonisolated static func descendants(of root: pid_t) -> [pid_t] {
        var found: [pid_t] = []
        var queue = [root]
        while let parent = queue.popLast(), found.count < 64 {
            let estimate = proc_listchildpids(parent, nil, 0)
            guard estimate > 0 else { continue }
            // Older systems answer in bytes, newer in pids: room for either, and only the filled slots count.
            var pids = [pid_t](repeating: 0, count: Int(estimate) + 16)
            _ = proc_listchildpids(parent, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
            let children = pids.filter { $0 > 0 && $0 != parent && !found.contains($0) }
            found += children
            queue += children
        }
        return found
    }

    /// What a child process is, in the user's words; else its executable's name.
    nonisolated static func kind(of pid: pid_t) -> String {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = Int(proc_pidpath(pid, &buffer, UInt32(buffer.count)))
        let name = length > 0 ? (String(decoding: buffer.prefix(length), as: UTF8.self) as NSString).lastPathComponent : "pid \(pid)"
        let lower = name.lowercased()
        if lower.hasPrefix("python") || lower == "uv" { return Localization.string("Tara's agent") }
        if lower == "perl" { return Localization.string("Media helper") }
        if lower == "claude" || lower == "node" { return "Claude Code" }
        if lower == "codex" { return "Codex" }
        if lower == "applemodel" { return "Apple Intelligence" }
        return name
    }
}
