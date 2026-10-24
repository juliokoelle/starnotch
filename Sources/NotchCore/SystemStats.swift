import Foundation

// System monitor logic without the system calls: CPU from tick deltas, memory from page counts,
// GPU from IORegistry statistics, processes grouped into apps, and when to warn.

/// Cumulative CPU ticks of one core (from `host_processor_info`).
public struct CoreTicks: Equatable, Sendable {
    public var user: UInt64
    public var system: UInt64
    public var idle: UInt64
    public var nice: UInt64

    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }

    var busy: UInt64 { user + system + nice }
    var total: UInt64 { busy + idle }
}

public enum CPULoad {
    /// Share of time busy between two samples, 0 to 1, overall and per core. Cores that went
    /// away or counters that wrapped count as idle.
    public static func usage(previous: [CoreTicks], current: [CoreTicks]) -> (total: Double, cores: [Double]) {
        var busy: UInt64 = 0, all: UInt64 = 0
        var cores: [Double] = []
        for (old, new) in zip(previous, current) {
            guard new.total >= old.total, new.busy >= old.busy else { cores.append(0); continue }
            let dBusy = new.busy - old.busy, dAll = new.total - old.total
            busy += dBusy
            all += dAll
            cores.append(dAll == 0 ? 0 : Double(dBusy) / Double(dAll))
        }
        return (all == 0 ? 0 : Double(busy) / Double(all), cores)
    }
}

/// Memory as Activity Monitor counts it.
public struct MemoryStats: Equatable, Sendable {
    public enum Pressure: Int, Sendable { case normal = 1, warn = 2, critical = 4 }

    public var total: UInt64
    /// App memory + wired + compressed.
    public var used: UInt64
    public var app: UInt64
    public var wired: UInt64
    public var compressed: UInt64
    public var swapUsed: UInt64
    public var pressure: Pressure

    public init(total: UInt64, used: UInt64, app: UInt64, wired: UInt64, compressed: UInt64, swapUsed: UInt64, pressure: Pressure) {
        self.total = total
        self.used = used
        self.app = app
        self.wired = wired
        self.compressed = compressed
        self.swapUsed = swapUsed
        self.pressure = pressure
    }

    /// From `vm_statistics64` page counts: app = internal − purgeable, compressed = pages
    /// held by the compressor.
    public static func from(pageSize: UInt64, internalPages: UInt64, purgeablePages: UInt64, wiredPages: UInt64,
                            compressorPages: UInt64, total: UInt64, swapUsed: UInt64, pressureLevel: Int) -> MemoryStats {
        let app = (internalPages > purgeablePages ? internalPages - purgeablePages : 0) * pageSize
        let wired = wiredPages * pageSize
        let compressed = compressorPages * pageSize
        return MemoryStats(total: total, used: min(total, app + wired + compressed), app: app, wired: wired,
                           compressed: compressed, swapUsed: swapUsed,
                           pressure: Pressure(rawValue: pressureLevel) ?? (pressureLevel >= 4 ? .critical : .normal))
    }

    public var fraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
}

public enum GPUStats {
    /// "Device Utilization %" from an IOAccelerator's `PerformanceStatistics`, 0 to 1.
    public static func utilization(_ statistics: [String: Any]) -> Double? {
        for key in ["Device Utilization %", "GPU Activity(%)", "Renderer Utilization %"] {
            if let value = statistics[key] as? NSNumber { return min(1, max(0, value.doubleValue / 100)) }
            if let value = statistics[key] as? Int { return min(1, max(0, Double(value) / 100)) }
        }
        return nil
    }
}

/// One process at one moment.
public struct ProcessSample: Equatable, Sendable {
    public var pid: Int32
    /// Executable path (may be empty when unreadable).
    public var path: String
    public var name: String
    /// CPU, 1.0 = one core fully busy.
    public var cpu: Double
    /// Physical footprint in bytes.
    public var memory: UInt64

    public init(pid: Int32, path: String, name: String, cpu: Double, memory: UInt64) {
        self.pid = pid
        self.path = path
        self.name = name
        self.cpu = cpu
        self.memory = memory
    }
}

/// An app with its helpers summed up.
public struct AppUsage: Equatable, Sendable, Identifiable {
    public var id: String { key }
    /// Bundle path for apps, else the process name.
    public var key: String
    public var name: String
    /// The `.app` bundle, for its icon and to bring it forward.
    public var bundlePath: String?
    public var cpu: Double
    public var memory: UInt64
    public var processes: Int

    public init(key: String, name: String, bundlePath: String?, cpu: Double, memory: UInt64, processes: Int) {
        self.key = key
        self.name = name
        self.bundlePath = bundlePath
        self.cpu = cpu
        self.memory = memory
        self.processes = processes
    }
}

public enum ProcessGrouping {
    public enum Sort: String, Sendable { case cpu, memory }

    /// The outermost `.app` bundle in a path: helpers inside "Google Chrome.app/…/Helper.app"
    /// belong to Google Chrome.
    public static func bundle(of path: String) -> String? {
        if let range = path.range(of: ".app/") { return String(path[..<path.index(range.lowerBound, offsetBy: 4)]) }
        return path.hasSuffix(".app") ? path : nil
    }

    /// Who a process belongs to: Claude Code sessions, an app bundle, or the process itself.
    public static func owner(of process: ProcessSample) -> (key: String, name: String, bundle: String?) {
        let lower = process.path.lowercased()
        if process.name == "claude" || lower.contains("/claude/versions/") || lower.contains("@anthropic-ai/claude-code") {
            return ("claude-code", "Claude Code", nil)
        }
        if let bundle = bundle(of: process.path) {
            let name = (bundle as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            return (bundle, name, bundle)
        }
        return (process.name, process.name, nil)
    }

    /// Processes summed per owner, sorted, the top `limit`.
    public static func group(_ processes: [ProcessSample], sort: Sort, limit: Int = 5) -> [AppUsage] {
        var byKey: [String: AppUsage] = [:]
        for process in processes {
            let owner = owner(of: process)
            var usage = byKey[owner.key] ?? AppUsage(key: owner.key, name: owner.name, bundlePath: owner.bundle,
                                                     cpu: 0, memory: 0, processes: 0)
            usage.cpu += process.cpu
            usage.memory += process.memory
            usage.processes += 1
            byKey[owner.key] = usage
        }
        let sorted = byKey.values.sorted {
            switch sort {
            case .cpu: ($0.cpu, $0.memory, $0.name) > ($1.cpu, $1.memory, $1.name)
            case .memory: ($0.memory, $0.cpu, $0.name) > ($1.memory, $1.cpu, $1.name)
            }
        }
        return Array(sorted.prefix(limit))
    }
}

/// When the island should say the Mac is overloaded: memory pressure warn or critical, or the
/// CPU above 85 % for 30 seconds. One sneak per episode; a new one after it calmed down.
public struct SystemAlert: Equatable, Sendable {
    public enum Level: Int, Comparable, Sendable {
        case none, warn, critical
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    public static let cpuThreshold = 0.85
    public static let cpuDuration: TimeInterval = 30

    public private(set) var level = Level.none
    private var cpuHighSince: Date?
    private var announced = false

    public init() {}

    /// Feeds one sample; returns `true` when this sample starts an episode worth one sneak.
    public mutating func update(cpu: Double, pressure: MemoryStats.Pressure, now: Date) -> Bool {
        if cpu >= Self.cpuThreshold { cpuHighSince = cpuHighSince ?? now } else { cpuHighSince = nil }
        let cpuHot = cpuHighSince.map { now.timeIntervalSince($0) >= Self.cpuDuration } ?? false
        let next: Level = switch pressure {
        case .critical: .critical
        case .warn: .warn
        case .normal: cpuHot ? .warn : .none
        }
        level = next
        if next == .none { announced = false; return false }
        if announced { return false }
        announced = true
        return true
    }
}

public enum ByteText {
    /// "3.1 GB", "640 MB".
    public static func short(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 10 { return String(format: "%.0f GB", gb) }
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}
