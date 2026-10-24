import Darwin
import Foundation
import NotchCore

/// Drives the approvals socket from a test: a server with a fixed answer, a client like the hook.
public enum ApprovalHarness {
    /// Starts a server in a temp folder that answers every request with `decision` after `delay`;
    /// sends `json` like the hook; returns the reply (empty when none).
    public static func roundTrip(json: String, decision: ApprovalDecision?, delay: Double = 0,
                                 closeEarly: Bool = false) -> (reply: String, cancelled: Bool) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ap-\(UUID().uuidString.prefix(8))").path
        let path = dir + "/a.sock"
        let cancelled = Flag()
        let server = ApprovalServer(path: path, handler: { _, reply in
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { reply(decision) }
        }, onCancel: { _ in cancelled.set() })
        defer { server.stop(); try? FileManager.default.removeItem(atPath: dir) }
        do { try server.start() } catch { return ("start failed \(error) \(path.utf8.count)", false) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (i, b) in path.utf8.enumerated() { raw[i] = b }
        }
        let ok = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { return ("connect failed", false) }
        let bytes = Array((json + "\n").utf8)
        _ = write(fd, bytes, bytes.count)
        if closeEarly {
            usleep(100_000)
            close(fd)
            for _ in 0..<40 where !cancelled.value { usleep(50_000) }
            return ("", cancelled.value)
        }
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            reply.append(buffer, count: n)
        }
        close(fd)
        return (String(decoding: reply, as: UTF8.self), cancelled.value)
    }

    public static func socketMode(after start: Bool = true) -> (folder: Int, socket: Int) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ap-\(UUID().uuidString.prefix(8))").path
        let server = ApprovalServer(path: dir + "/a.sock", handler: { _, reply in reply(nil) })
        defer { server.stop(); try? FileManager.default.removeItem(atPath: dir) }
        try? server.start()
        func mode(_ p: String) -> Int {
            ((try? FileManager.default.attributesOfItem(atPath: p))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
        }
        return (mode(dir), mode(dir + "/a.sock"))
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var on = false
        var value: Bool { lock.lock(); defer { lock.unlock() }; return on }
        func set() { lock.lock(); on = true; lock.unlock() }
    }
}
