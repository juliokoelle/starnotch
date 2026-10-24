import NotchCore
/// A running process, reduced to what the leftover cleanup needs.
public struct ProcessSnapshot: Equatable, Sendable {
    public var pid: Int32
    public var parentPID: Int32
    /// `argv`, including `argv[0]`.
    public var arguments: [String]

    public init(pid: Int32, parentPID: Int32, arguments: [String]) {
        self.pid = pid
        self.parentPID = parentPID
        self.arguments = arguments
    }

    /// Extracts `argv` from a `KERN_PROCARGS2` sysctl buffer: a 32-bit `argc`, the executable
    /// path, NUL padding, then `argc` NUL-terminated arguments (followed by the environment).
    /// Returns what it could read completely; an empty array for malformed buffers.
    public static func arguments(fromProcArgs2 bytes: [UInt8]) -> [String] {
        guard bytes.count >= 4 else { return [] }
        let argc = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
        var index = 4
        while index < bytes.count, bytes[index] != 0 { index += 1 }  // executable path
        while index < bytes.count, bytes[index] == 0 { index += 1 }  // padding
        var arguments: [String] = []
        while arguments.count < argc, index < bytes.count {
            guard let end = bytes[index...].firstIndex(of: 0) else { break }
            arguments.append(String(decoding: bytes[index..<end], as: UTF8.self))
            index = end + 1
        }
        return arguments
    }
}

/// Finds helper processes that a quit notch app left behind.
///
/// Boring Notch 2.7.3, for example, starts `/usr/bin/perl …/boringNotch.app/…/mediaremote-adapter.pl`
/// and doesn't stop it when it quits. Without cleanup every switch away from it would leave
/// one more Perl process running.
public enum LeftoverProcesses {
    /// - Parameters:
    ///   - processes: Snapshot of the running processes.
    ///   - bundlePaths: Bundle paths of the apps that have just quit.
    ///   - excluding: Process IDs that must never be selected (e.g. the app itself).
    /// - Returns: Orphans (re-parented to launchd) whose executable or arguments point inside
    ///   one of the bundles. Processes with a living parent are left alone.
    public static func select(
        _ processes: [ProcessSnapshot],
        bundlePaths: [String],
        excluding: Set<Int32> = []
    ) -> [Int32] {
        let prefixes = bundlePaths.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        guard !prefixes.isEmpty else { return [] }
        return processes.compactMap { process in
            guard process.pid > 1, process.parentPID == 1, !excluding.contains(process.pid) else { return nil }
            let insideBundle = process.arguments.contains { argument in
                prefixes.contains { argument.hasPrefix($0) }
            }
            return insideBundle ? process.pid : nil
        }
    }
}
