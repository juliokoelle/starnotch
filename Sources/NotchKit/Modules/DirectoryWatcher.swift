import NotchCore
import CoreServices
import Foundation

/// Calls back shortly after anything in a directory changes (FSEvents). Read-only: it only
/// observes. Used on `~/.claude/sessions`, where Claude Code flips a session between busy and
/// idle, so finished and your-turn moments show within about a second instead of the next poll.
final class DirectoryWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let onChange: @Sendable () -> Void

    init?(path: String, latency: TimeInterval = 0.25, onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: Brand.identifier + ".fsevents"))
        FSEventStreamStart(stream)
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
