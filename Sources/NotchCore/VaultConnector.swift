import Foundation

/// Your notes as a connector: an Obsidian vault or any folder of Markdown files. Today shows the
/// tasks due today or overdue, what comes up this week and the headings of today's note; a task
/// ticked off in the notch becomes `- [x]` in its file; quick capture appends to the inbox; Tara
/// reads a snapshot (`connectors/vault.json`).
///
/// Picked in Settings › Notes, or in config.toml (which wins):
///
///     [connectors.vault]
///     folder = "~/notes"
///     tasks = "Tasks.md"              # a file, or a folder of Markdown files with "- [ ]" tasks
///     daily = "Daily/YYYY-MM-DD.md"   # the daily note's path pattern
///     inbox = "Inbox.md"              # quick capture appends here
///     loops = "loops/RUNLOG.md"       # the loops' run log (unless [connectors.runlog] names one)
///
/// Paths are relative to the folder unless they start with `/` or `~`. A due date is written
/// `📅 2026-10-28`, `[due:: 2026-10-28]` or `(due 2026-10-28)`.
public final class VaultConnector: NotchConnector, TodayCompleting, @unchecked Sendable {
    public static let id = "vault"
    public static let displayName = "Notes"

    /// Settings' choices (UserDefaults) when config.toml has no `[connectors.vault]` value.
    public enum Key {
        public static let folder = "vault.folder"
        public static let tasks = "vault.tasks"
        public static let daily = "vault.daily"
        public static let inbox = "vault.inbox"
    }

    private let config: ConfigSection
    private let defaults: UserDefaults
    /// Where `writeSnapshot` writes for Tara.
    public let snapshotURL: URL?
    private let lock = NSLock()
    private var cache: (key: String, tasks: [VaultTask])?
    private var dailyCache: (key: String, text: String)?

    public init(config: ConfigSection, defaults: UserDefaults,
                snapshotURL: URL? = Brand.supportFolder.appending(path: "connectors/vault.json")) {
        self.config = config
        self.defaults = defaults
        self.snapshotURL = snapshotURL
    }

    public convenience init(config: ConfigSection) {
        self.init(config: config, defaults: .standard)
    }

    // MARK: Where things are

    /// The vault folder: config.toml first, else the one picked in Settings.
    public var folder: URL? {
        config.path("folder") ?? defaults.string(forKey: Key.folder).flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    }

    /// Whether the folder names one that exists.
    public var isConfigured: Bool {
        var directory: ObjCBool = false
        guard let folder else { return false }
        return FileManager.default.fileExists(atPath: folder.path, isDirectory: &directory) && directory.boolValue
    }

    /// Whether config.toml sets the folder (Settings then shows it read-only).
    public var isFromConfig: Bool { config.path("folder") != nil }

    /// The files as configured, relative to the folder; config.toml wins key by key, and `""`
    /// there means "none".
    public var layout: VaultLayout {
        func value(_ key: String, _ defaultsKey: String) -> String? {
            if let raw = config.string(key) { return raw.trimmingCharacters(in: .whitespaces).isEmpty ? nil : raw }
            return defaults.string(forKey: defaultsKey).flatMap { $0.isEmpty ? nil : $0 }
        }
        return VaultLayout(tasks: value("tasks", Key.tasks), daily: value("daily", Key.daily),
                           inbox: value("inbox", Key.inbox), loops: config.string("loops"))
    }

    /// A configured path as a file URL: relative to the folder, or absolute, or `~/…`.
    public func resolve(_ path: String) -> URL? {
        let raw = path.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        if raw.hasPrefix("/") { return URL(fileURLWithPath: raw) }
        if raw == "~" || raw.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser.appending(path: String(raw.dropFirst(min(2, raw.count))))
        }
        return folder?.appending(path: raw)
    }

    public var tasksURL: URL? { isConfigured ? layout.tasks.flatMap(resolve) : nil }
    /// Where quick capture appends, when an inbox is set.
    public var inboxFile: URL? { isConfigured ? layout.inbox.flatMap(resolve) : nil }
    public var loopsFile: URL? { layout.loops.flatMap(resolve) }

    public func dailyURL(for date: Date) -> URL? {
        guard isConfigured, let pattern = layout.daily else { return nil }
        return resolve(DailyNote.path(pattern: pattern, date: date))
    }

    /// An Obsidian vault opens its notes in Obsidian; any other folder in the default app.
    public var isObsidian: Bool {
        folder.map { FileManager.default.fileExists(atPath: $0.appending(path: ".obsidian").path) } ?? false
    }

    /// Where a click on a note goes.
    public func link(to file: URL) -> URL {
        guard isObsidian, var components = URLComponents(string: "obsidian://open") else { return file }
        components.queryItems = [URLQueryItem(name: "path", value: file.path)]
        return components.url ?? file
    }

    // MARK: Tasks

    /// Every open task in the tasks file or folder; cached by the files' modification times.
    public func openTasks() -> [VaultTask] {
        guard let root = tasksURL, let folder else { return [] }
        let files = Self.taskFiles(at: root)
        let key = files.map { "\($0.path):\(Self.mtime($0)?.timeIntervalSince1970 ?? 0)" }.joined(separator: "|")
        if let cached = lock.withLock({ cache }), cached.key == key { return cached.tasks }
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path
        var tasks: [VaultTask] = []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let path = file.standardizedFileURL.resolvingSymlinksInPath().path
            let relative = path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path
            tasks += MarkdownTasks.parse(text, file: relative)
        }
        lock.withLock { cache = (key, tasks) }
        return tasks
    }

    /// A file, or the Markdown files in a folder (hidden ones skipped).
    static func taskFiles(at root: URL) -> [URL] {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &directory) else { return [] }
        guard directory.boolValue else { return [root] }
        return VaultDetect.markdownFiles(in: root, maxDepth: 6).sorted().map { root.appending(path: $0) }
    }

    public func canComplete(_ id: String) -> Bool {
        lock.withLock { cache?.tasks.first { $0.id == id } }.map { !$0.repeats } ?? false
    }

    /// Ticks the task off in its file: the line must still be there exactly as read, and the file
    /// must not change while it is written; otherwise nothing is written.
    public func complete(_ id: String) -> Bool {
        guard let task = lock.withLock({ cache?.tasks.first { $0.id == id } }), !task.repeats,
              let file = resolve(task.file) else { return false }
        var written = false
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: file, options: .forMerging, error: &error) { url in
            written = Self.tickOff(task, at: url)
        }
        if written { lock.withLock { cache = nil } }
        return written
    }

    static func tickOff(_ task: VaultTask, at url: URL) -> Bool {
        guard let before = try? Data(contentsOf: url), let text = String(data: before, encoding: .utf8),
              let updated = MarkdownTasks.completing(task, in: text),
              updated.utf8.count == text.utf8.count else { return false }
        // Changed by someone else since the read: leave it, the next look shows the new state.
        guard let again = try? Data(contentsOf: url), again == before else { return false }
        do {
            try Data(updated.utf8).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: Today

    public func today(now: Date) -> TodayFeed {
        guard isConfigured else { return TodayFeed(nowTitle: L("Due today"), emptyText: L("Pick your notes folder in Settings.")) }
        let tasks = openTasks()
        let day = RunLog.day(now)
        let week = RunLog.day(now.addingTimeInterval(7 * 86_400))
        let byDue = { (lhs: VaultTask, rhs: VaultTask) in
            (lhs.due ?? "", lhs.time ?? "99", lhs.file, lhs.line) < (rhs.due ?? "", rhs.time ?? "99", rhs.file, rhs.line)
        }
        let due = tasks.filter { ($0.due ?? "9999") <= day }.sorted(by: byDue)
        let coming = tasks.filter { guard let date = $0.due else { return false }; return date > day && date <= week }.sorted(by: byDue)

        var brief: TodayBrief?
        if let note = dailyURL(for: now), let text = dailyText(note) {
            let headings = DailyNote.headings(text)
            brief = TodayBrief(title: L("Today's note"), text: headings.isEmpty ? DailyNote.body(text, limit: 160) : headings.joined(separator: " · "))
        }
        var counters = [TodayCounter(label: L("Open (count)"), value: tasks.count, help: L("Open tasks in your notes"),
                                     url: tasksURL.map(link(to:)))]
        if let inbox = inboxFile, let text = try? String(contentsOf: inbox, encoding: .utf8) {
            counters.append(TodayCounter(label: L("Inbox"), value: MarkdownTasks.openCount(text), help: L("Open lines in your inbox"),
                                         url: link(to: inbox)))
        }
        let home = folder.map { TodayLink(title: isObsidian ? "Obsidian" : L("Notes"), url: link(to: $0)) }
        return TodayFeed(now: due.map { item($0, now: now) }, followUps: coming.map { item($0, now: now) },
                         brief: brief, counters: counters, home: home,
                         nowTitle: L("Due today"), followUpTitle: L("Coming up"), emptyText: L("Nothing due today."))
    }

    private func item(_ task: VaultTask, now: Date) -> TodayItem {
        let file = resolve(task.file)
        var notes = task.notes
        if !task.tags.isEmpty { notes.append(task.tags.map { "#" + $0 }.joined(separator: " ")) }
        return TodayItem(id: task.id, kind: .task, title: task.title.isEmpty ? task.detail : task.title,
                         detail: task.title.isEmpty ? "" : task.detail, date: task.due,
                         url: file.map(link(to:)), help: isObsidian ? L("Open in Obsidian") : L("Open the note"),
                         group: task.section.isEmpty ? (task.file as NSString).deletingPathExtension : task.section,
                         notes: notes)
    }

    private func dailyText(_ url: URL) -> String? {
        let key = "\(url.path):\(Self.mtime(url)?.timeIntervalSince1970 ?? -1)"
        if let cached = lock.withLock({ dailyCache }), cached.key == key { return cached.text }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        lock.withLock { dailyCache = (key, text) }
        return text
    }

    // MARK: For Tara

    /// What Tara's brain reads: open tasks, today's note, the notes touched last.
    public func snapshot(now: Date, recent: Int = 15) -> VaultSnapshot? {
        guard isConfigured, let folder else { return nil }
        let tasks = openTasks()
        let dated = tasks.filter { $0.due != nil }.sorted { ($0.due ?? "", $0.file, $0.line) < ($1.due ?? "", $1.file, $1.line) }
        let ordered = dated + tasks.filter { $0.due == nil }
        var daily: VaultSnapshot.DailyNote?
        if let pattern = layout.daily, let url = dailyURL(for: now), let text = dailyText(url) {
            daily = .init(path: DailyNote.path(pattern: pattern, date: now), headings: DailyNote.headings(text), text: DailyNote.body(text))
        }
        return VaultSnapshot(updated: now, name: folder.lastPathComponent, today: RunLog.day(now), tasks: Array(ordered.prefix(300)),
                             openTasks: tasks.count, dailyNote: daily, recentNotes: Self.recentNotes(in: folder, limit: recent))
    }

    /// Writes the snapshot (0600) where the ask strand of the agent finds it; removes it when
    /// no vault is set, so nothing stale stays behind.
    @discardableResult
    public func writeSnapshot(now: Date = Date()) -> Bool {
        guard let snapshotURL else { return false }
        let fm = FileManager.default
        guard let snapshot = snapshot(now: now) else {
            try? fm.removeItem(at: snapshotURL)
            return false
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return false }
        try? fm.createDirectory(at: snapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        do {
            try data.write(to: snapshotURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshotURL.path)
            return true
        } catch {
            return false
        }
    }

    /// The Markdown notes changed last.
    static func recentNotes(in folder: URL, limit: Int) -> [VaultSnapshot.Note] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path
        var notes: [VaultSnapshot.Note] = []
        var seen = 0
        for case let url as URL in walker {
            seen += 1
            if seen > 20_000 { break }
            guard url.pathExtension.lowercased() == "md",
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let modified = values.contentModificationDate else { continue }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            let relative = path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : url.lastPathComponent
            notes.append(.init(title: url.deletingPathExtension().lastPathComponent, path: relative, modified: modified))
        }
        return Array(notes.sorted { $0.modified > $1.modified }.prefix(limit))
    }

    static func mtime(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// The app's translation of a line, when it has one (Resources/Localization).
    private func L(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }
}
