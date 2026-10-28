import Foundation

/// `KERN_PROCARGS2` bytes as macOS lays them out.
public enum ProcArgsSample {
    public static func bytes(arguments: [String], environment: [String]) -> [UInt8] {
        var bytes: [UInt8] = []
        let argc = UInt32(arguments.count)
        bytes += [UInt8(argc & 0xFF), UInt8(argc >> 8 & 0xFF), UInt8(argc >> 16 & 0xFF), UInt8(argc >> 24 & 0xFF)]
        bytes += Array("/usr/local/bin/tool".utf8) + [0, 0, 0, 0]
        for argument in arguments { bytes += Array(argument.utf8) + [0] }
        for entry in environment { bytes += Array(entry.utf8) + [0] }
        bytes += [0, 0]
        return bytes
    }
}
