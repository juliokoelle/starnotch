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
