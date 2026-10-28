import CoreServices
import Foundation
import NotchCore

/// Keeps the notes connector live: watches the vault folder with FSEvents (no polling), and when
/// a note changes rewrites Tara's snapshot and tells Today. Hidden folders (.obsidian, .git,
/// .trash) and files other than Markdown don't count, so clicking around in Obsidian costs nothing.
@MainActor
final class VaultLive {
    /// Posted when the folder or files are picked anew in Settings or onboarding.
    static let changed = Notification.Name(Brand.identifier + ".vault-changed")

    let connector: VaultConnector
    /// A note changed: Today reads again.
    var onChange: (() -> Void)?
    /// The folder was set, changed or removed: whether Today is available may have changed.
    var onReconfigure: (() -> Void)?
    /// Tara's privacy switches: no new snapshot while paused or with notes off.
    var privacy: () -> MemoryPrivacy = { MemoryPrivacy() }
    private var watcher: NoteWatcher?
    private var watchedPath: String?
    private var pending: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    init(connector: VaultConnector) {
        self.connector = connector
    }

    func start() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: Self.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.restart()
                self?.onReconfigure?()
            }
        })
        // A new day: another daily note, other tasks due.
        observers.append(center.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule(after: .zero) }
        })
        restart()
    }

    /// Watches the folder as configured now and writes a fresh snapshot.
    func restart() {
        let path = connector.isConfigured ? connector.folder?.path : nil
        if path != watchedPath {
            watcher = path.flatMap { NoteWatcher(path: $0) { [weak self] in
                Task { @MainActor in self?.schedule(after: .seconds(1.5)) }
            } }
            watchedPath = path
        }
        schedule(after: .zero)
    }

    /// Several saves in a row write the snapshot once.
    private func schedule(after delay: Duration) {
        pending?.cancel()
        pending = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let connector = self?.connector else { return }
            if self?.privacy().records(.notes, at: Date()) == true {
                _ = await Task.detached(priority: .utility) { connector.writeSnapshot() }.value
            }
            self?.onChange?()
        }
    }
}

/// FSEvents on a folder, reporting only changes to visible Markdown files.
private final class NoteWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let root: String
    private let onChange: @Sendable () -> Void

    init?(path: String, onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        root = path.hasSuffix("/") ? path : path + "/"
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<NoteWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            guard list.prefix(count).contains(where: watcher.counts) else { return }
            watcher.onChange()
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: Brand.identifier + ".vault", qos: .utility))
        FSEventStreamStart(stream)
    }

    /// A Markdown file outside hidden folders of the vault.
    func counts(_ path: String) -> Bool {
        let inside = path.hasPrefix(root) ? String(path.dropFirst(root.count)) : (path as NSString).lastPathComponent
        return inside.lowercased().hasSuffix(".md") && !inside.split(separator: "/").contains { $0.hasPrefix(".") }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
