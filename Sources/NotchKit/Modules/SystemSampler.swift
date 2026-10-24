import Darwin
import Foundation
import IOKit
import NotchCore

/// Reads CPU, memory, GPU and per-process usage with plain system calls: no helper, no sudo, no
/// permission. Processes of other users (root daemons) can't be read and are left out, as in
/// Activity Monitor's "My Processes". Not thread-safe: one sampler per queue.
final class SystemSampler: @unchecked Sendable {
    struct Reading: Sendable {
        var cpu: Double
        var cores: [Double]
        var gpu: Double?
        var memory: MemoryStats
        /// Empty unless asked for.
        var processes: [ProcessSample]
        var date: Date
    }

    private var lastTicks: [CoreTicks] = []
    private var lastProcessTimes: [Int32: (start: UInt64, cpu: UInt64)] = [:]
    private var lastProcessDate: Date?
    private var paths: [Int32: (start: UInt64, path: String)] = [:]
    private let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(1, info.denom)))
    }()
    private let pageSize: UInt64 = SystemSampler.sysctlUInt64("hw.pagesize") ?? 16_384
    private let totalMemory: UInt64 = SystemSampler.sysctlUInt64("hw.memsize") ?? 0

    func read(processes wantProcesses: Bool, now: Date = Date()) -> Reading {
        let ticks = Self.coreTicks()
        let load = lastTicks.isEmpty ? (total: 0.0, cores: [Double]()) : CPULoad.usage(previous: lastTicks, current: ticks)
        lastTicks = ticks
        return Reading(cpu: load.total, cores: load.cores, gpu: Self.gpuUtilization(), memory: memory(),
                       processes: wantProcesses ? processes(now: now) : [], date: now)
    }

    // MARK: CPU

    static func coreTicks() -> [CoreTicks] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let states = Int(CPU_STATE_MAX)
        return (0..<Int(count)).map { core in
            func tick(_ state: Int32) -> UInt64 { UInt64(UInt32(bitPattern: info[core * states + Int(state)])) }
            return CoreTicks(user: tick(CPU_STATE_USER), system: tick(CPU_STATE_SYSTEM), idle: tick(CPU_STATE_IDLE),
                             nice: tick(CPU_STATE_NICE))
        }
    }

    // MARK: Memory

    private func memory() -> MemoryStats {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let swapUsed = sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 ? UInt64(swap.xsu_used) : 0
        let pressure = Int(Self.sysctlUInt64("kern.memorystatus_vm_pressure_level") ?? 1)
        guard result == KERN_SUCCESS else {
            return MemoryStats(total: totalMemory, used: 0, app: 0, wired: 0, compressed: 0, swapUsed: swapUsed,
                               pressure: MemoryStats.Pressure(rawValue: pressure) ?? .normal)
        }
        return MemoryStats.from(pageSize: pageSize, internalPages: UInt64(stats.internal_page_count),
                                purgeablePages: UInt64(stats.purgeable_count), wiredPages: UInt64(stats.wire_count),
                                compressorPages: UInt64(stats.compressor_page_count), total: totalMemory,
                                swapUsed: swapUsed, pressureLevel: pressure)
    }

    static func sysctlUInt64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        if sysctlbyname(name, &value, &size, nil, 0) == 0 {
            return size == 4 ? UInt64(UInt32(truncatingIfNeeded: value)) : value
        }
        return nil
    }

    // MARK: GPU

    static func gpuUtilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let property = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any], let value = GPUStats.utilization(property) else { continue }
            best = max(best ?? 0, value)
        }
        return best
    }

    // MARK: Processes

    private func processes(now: Date) -> [ProcessSample] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [Int32](repeating: 0, count: max(capacity, 64))
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size)))
        let elapsed = lastProcessDate.map { now.timeIntervalSince($0) } ?? 0
        var samples: [ProcessSample] = []
        var times: [Int32: (start: UInt64, cpu: UInt64)] = [:]
        for pid in pids.prefix(max(0, count)) where pid > 0 {
            var usage = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard ok == 0 else { continue }
            let cpuTime = (usage.ri_user_time + usage.ri_system_time) * timebase.numer / timebase.denom  // ns
            let start = usage.ri_proc_start_abstime
            times[pid] = (start, cpuTime)
            var cpu = 0.0
            if elapsed > 0, let last = lastProcessTimes[pid], last.start == start, cpuTime >= last.cpu {
                cpu = Double(cpuTime - last.cpu) / 1e9 / elapsed
            }
            let path = path(of: pid, start: start)
            samples.append(ProcessSample(pid: pid, path: path, name: (path as NSString).lastPathComponent,
                                         cpu: cpu, memory: usage.ri_phys_footprint))
        }
        lastProcessTimes = times
        lastProcessDate = now
        paths = paths.filter { times[$0.key]?.start == $0.value.start }
        return samples
    }

    private func path(of pid: Int32, start: UInt64) -> String {
        if let cached = paths[pid], cached.start == start { return cached.path }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let path = length > 0 ? String(cString: buffer) : ""
        paths[pid] = (start, path)
        return path
    }
}
