import Darwin
import Foundation

/// The process list, read with libproc (no subprocess, no permission): terminal devices,
/// working directories and parent chains of the user's own processes.
public enum Processes {
    /// "/dev/ttys003" for a process attached to a terminal; nil for GUI-hosted ones.
    public static func tty(of pid: Int32) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let device = dev_t(bitPattern: info.e_tdev)
        guard device != -1, device != 0, let name = devname(device, S_IFCHR) else { return nil }
        let text = String(cString: name)
        return text.hasPrefix("ttys") ? "/dev/" + text : nil
    }

    public static func parent(of pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let parent = Int32(info.pbi_ppid)
        return parent > 1 && parent != pid ? parent : nil
    }

    public static func cwd(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            let bytes = raw.bindMemory(to: CChar.self)
            return bytes.baseAddress.map { String(cString: $0) }
        }?.nilIfEmpty
    }

    public static func executable(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// The user's processes whose executable is named `name` ("codex"), with cwd and terminal.
    public static func named(_ name: String) -> [(pid: Int32, cwd: String?, tty: String?)] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard filled > 0 else { return [] }
        let me = getuid()
        var result: [(Int32, String?, String?)] = []
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == me else { continue }
            let comm = withUnsafeBytes(of: &info.pbi_comm) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            guard comm == name else { continue }
            result.append((pid, cwd(of: pid), tty(of: pid)))
        }
        return result
    }
}

// MARK: Arguments, environment and agent CLIs

extension Processes {
    /// A running agent CLI: its process, folder and terminal.
    public struct AgentProcess: Equatable, Sendable {
        public var pid: Int32
        public var cwd: String?
        public var tty: String?

        public init(pid: Int32, cwd: String?, tty: String?) {
            self.pid = pid
            self.cwd = cwd
            self.tty = tty
        }
    }

    /// Arguments and environment of one of the user's own processes (`KERN_PROCARGS2`, the way
    /// `ps eww` reads them); nil when macOS refuses or the process is gone.
    public static func arguments(of pid: Int32) -> (arguments: [String], environment: [String: String])? {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(argmax))
        mib = [CTL_KERN, KERN_PROCARGS2, pid]
        size = buffer.count
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parseProcArgs(Array(buffer.prefix(size)))
    }

    /// `KERN_PROCARGS2`'s layout: argc, the executable path, padding, argc arguments, then the
    /// environment as KEY=value strings up to an empty one.
    public static func parseProcArgs(_ bytes: [UInt8]) -> (arguments: [String], environment: [String: String])? {
        guard bytes.count > 4 else { return nil }
        let argc = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
        var index = 4
        // The executable path, then NUL padding.
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        func next() -> String? {
            guard index < bytes.count else { return nil }
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
            index += 1
            return text
        }
        var arguments: [String] = []
        for _ in 0..<max(0, argc) {
            guard let argument = next() else { break }
            arguments.append(argument)
        }
        var environment: [String: String] = [:]
        while let entry = next(), !entry.isEmpty {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        return (arguments, environment)
    }

    /// The user's processes running an agent CLI: an executable named one of `names`, or a
    /// runtime (`node`, `bun`) whose arguments contain one of `scripts` ("gemini-cli").
    public static func agents(names: Set<String>, scripts: [String] = []) -> [AgentProcess] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard filled > 0 else { return [] }
        let me = getuid()
        var result: [AgentProcess] = []
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == me else { continue }
            let comm = withUnsafeBytes(of: &info.pbi_comm) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            var match = names.contains(comm)
            if !match, !scripts.isEmpty, ["node", "bun"].contains(comm),
               let args = arguments(of: pid)?.arguments.prefix(3) {
                match = args.contains { arg in scripts.contains { arg.contains($0) } }
            }
            guard match else { continue }
            result.append(AgentProcess(pid: pid, cwd: cwd(of: pid), tty: tty(of: pid)))
        }
        return result
    }
}
