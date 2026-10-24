import Darwin
import NotchCore

/// Reads the current user's processes (pid, parent, argv) through libproc and sysctl.
enum ProcessList {
    static func snapshot() -> [ProcessSnapshot] {
        let capacity = proc_listallpids(nil, 0) + 64
        guard capacity > 64 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity))
        let count = proc_listallpids(&pids, capacity * Int32(MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        let uid = getuid()
        return pids.prefix(Int(count)).compactMap { pid in
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard pid > 1, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  info.pbi_uid == uid else { return nil }
            return ProcessSnapshot(pid: pid, parentPID: Int32(info.pbi_ppid), arguments: arguments(of: pid))
        }
    }

    private static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        return ProcessSnapshot.arguments(fromProcArgs2: Array(buffer.prefix(size)))
    }
}
