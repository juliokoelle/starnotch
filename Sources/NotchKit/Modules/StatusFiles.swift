import Foundation
import NotchCore

/// The files `scripts/statusline-bridge.sh` writes: one JSON per Claude Code session.
enum StatusFiles {
    static var folder: URL { APIToken.folder.appending(path: "status") }
    /// Sessions that haven't updated in two days are gone.
    static let maxAge: TimeInterval = 2 * 86_400

    static func read(now: Date = Date()) -> [String: StatusSnapshot] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var result: [String: StatusSnapshot] = [:]
        for file in files where file.pathExtension == "json" && !file.lastPathComponent.hasPrefix(".") {
            guard let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  now.timeIntervalSince(mtime) < maxAge,
                  let data = try? Data(contentsOf: file),
                  let snapshot = StatusSnapshot.parse(data, capturedAt: mtime) else { continue }
            result[snapshot.sessionID] = snapshot
        }
        return result
    }

    /// The setup note in the app bundle (falls back to the repo's copy).
    static var setupGuide: URL? {
        Bundle.main.url(forResource: "usage-setup", withExtension: "md")
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "docs/usage-setup.md")
    }
}
