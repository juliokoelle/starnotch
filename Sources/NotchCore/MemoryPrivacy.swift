import Foundation

// Privacy controls for Tara's memory: pause it, switch sources off, keep apps out, and delete
// what she remembers per source. Pure decisions and file lists; the app and the sidecar
// (`agent/privacy.py`, through `privacy.json`) follow them.

/// What Tara remembers, one switch each.
public enum MemorySource: String, Codable, CaseIterable, Sendable {
    /// Meetings: transcripts, Jamie's meetings, the prep cards' feed, today's calendar.
    case meetings
    /// Quick captures (⌃⌥N): tasks, questions and notes.
    case captures
    /// The notes vault and other tools' snapshots (`connectors/`).
    case notes
    /// Clipboard history (in memory only, never on disk).
    case clipboard
    /// Your agent sessions (Claude Code's recent sessions); Starnotch keeps no copy of them.
    case sessions

    public var title: String {
        switch self {
        case .meetings: "Meetings and calendar"
        case .captures: "Quick captures"
        case .notes: "Notes vault"
        case .clipboard: "Clipboard history"
        case .sessions: "Agent sessions"
        }
    }

    public var detail: String {
        switch self {
        case .meetings: "Transcripts, meetings synced from Jamie, today's calendar"
        case .captures: "Tasks, questions and notes you jot down with ⌃⌥N"
        case .notes: "Tasks and today's note from your vault, snapshots from other tools"
        case .clipboard: "What you copy, kept in memory until Starnotch quits"
        case .sessions: "Titles and folders of your recent agent sessions"
        }
    }

    public var symbol: String {
        switch self {
        case .meetings: "person.2.wave.2"
        case .captures: "square.and.pencil"
        case .notes: "book.closed"
        case .clipboard: "doc.on.clipboard"
        case .sessions: "terminal"
        }
    }
}

/// How long a pause lasts.
public enum MemoryPause: String, CaseIterable, Sendable {
    case oneHour, untilTomorrow, untilResumed

    public var title: String {
        switch self {
        case .oneHour: "For 1 hour"
        case .untilTomorrow: "Until tomorrow"
        case .untilResumed: "Until I resume"
        }
    }

    /// When a pause started `now` ends; `.distantFuture` for one that lasts until resumed.
    public func end(from now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .oneHour: now.addingTimeInterval(3600)
        case .untilTomorrow: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)
        case .untilResumed: .distantFuture
        }
    }
}

/// An app whose activity Tara never records.
public struct IgnoredApp: Codable, Equatable, Hashable, Sendable {
    public var bundleID: String
    public var name: String

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// The privacy switches, saved with the settings and mirrored to `privacy.json` for the sidecar.
public struct MemoryPrivacy: Codable, Equatable, Sendable {
    /// Paused until then (`.distantFuture`: until resumed); nil while not paused.
    public var pausedUntil: Date?
    /// Sources switched off; all are on by default.
    public var off: [MemorySource]
    /// Apps the user added to the ignore list (the password apps are always on it).
    public var ignoredApps: [IgnoredApp]

    public init(pausedUntil: Date? = nil, off: [MemorySource] = [], ignoredApps: [IgnoredApp] = []) {
        self.pausedUntil = pausedUntil
        self.off = off
        self.ignoredApps = ignoredApps
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pausedUntil = try? c.decodeIfPresent(Date.self, forKey: .pausedUntil)
        // A source this version doesn't know is dropped, the rest kept.
        off = ((try? c.decodeIfPresent([String].self, forKey: .off)) ?? []).compactMap(MemorySource.init(rawValue:))
        ignoredApps = (try? c.decodeIfPresent([IgnoredApp].self, forKey: .ignoredApps)) ?? []
    }

    /// Password apps: never recorded, whatever the list says.
    public static let passwordApps: [IgnoredApp] = [
        .init(bundleID: "com.1password.1password", name: "1Password"),
        .init(bundleID: "com.agilebits.onepassword7", name: "1Password 7"),
        .init(bundleID: "com.bitwarden.desktop", name: "Bitwarden"),
        .init(bundleID: "com.apple.keychainaccess", name: "Keychain Access"),
        .init(bundleID: "com.apple.Passwords", name: "Passwords"),
        .init(bundleID: "com.lastpass.LastPass", name: "LastPass"),
        .init(bundleID: "com.dashlane.dashlanephonefinal", name: "Dashlane"),
    ]

    // MARK: Decisions

    public func isPaused(at now: Date) -> Bool { pausedUntil.map { now < $0 } ?? false }

    /// A pause that lasts until the user resumes it.
    public var isPausedUntilResumed: Bool { pausedUntil.map { $0 >= .distantFuture } ?? false }

    public func isOn(_ source: MemorySource) -> Bool { !off.contains(source) }

    /// Every app Tara keeps out: the password apps and the user's list.
    public var ignoredBundleIDs: Set<String> { Set((Self.passwordApps + ignoredApps).map(\.bundleID)) }

    public func ignores(app bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return ignoredBundleIDs.contains(bundleID)
    }

    /// May Tara record something new from `source` now (made in `app`, when known)? Not while
    /// paused, not from a source that's off, never from an ignored app.
    public func records(_ source: MemorySource, at now: Date, app bundleID: String? = nil) -> Bool {
        !isPaused(at: now) && isOn(source) && !ignores(app: bundleID)
    }

    /// May Tara use what she has from `source` in answers and hand it to AI apps? A pause only
    /// stops recording; a source that's off is left out.
    public func shares(_ source: MemorySource) -> Bool { isOn(source) }

    // MARK: Changes

    public mutating func pause(_ length: MemoryPause, now: Date, calendar: Calendar = .current) {
        pausedUntil = length.end(from: now, calendar: calendar)
    }

    public mutating func resume() { pausedUntil = nil }

    /// Drops a pause that has run out, so the saved state says what is true.
    public mutating func expire(at now: Date) {
        if let until = pausedUntil, now >= until { pausedUntil = nil }
    }

    public mutating func set(_ source: MemorySource, on: Bool) {
        off.removeAll { $0 == source }
        if !on { off.append(source) }
        off.sort { a, b in MemorySource.allCases.firstIndex(of: a)! < MemorySource.allCases.firstIndex(of: b)! }
    }

    /// Adds an app to the ignore list (once; password apps are on it already).
    public mutating func ignore(_ app: IgnoredApp) {
        guard !ignoredBundleIDs.contains(app.bundleID) else { return }
        ignoredApps.append(app)
        ignoredApps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public mutating func unignore(_ bundleID: String) { ignoredApps.removeAll { $0.bundleID == bundleID } }

    // MARK: For the sidecar

    /// `privacy.json`: `{"paused": true, "paused_until": "…Z" or null, "off": [...], "ignored_apps": [...]}`.
    /// `paused_until` is null for a pause that lasts until resumed; a pause that ran out isn't written.
    public func sidecarJSON(now: Date) -> Data {
        let paused = isPaused(at: now)
        var object: [String: Any] = [
            "paused": paused,
            "off": off.map(\.rawValue),
            "ignored_apps": ignoredBundleIDs.sorted(),
        ]
        if paused, let until = pausedUntil, !isPausedUntilResumed {
            object["paused_until"] = ISO8601DateFormatter().string(from: until)
        } else {
            object["paused_until"] = NSNull()
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
    }

    /// Writes `privacy.json` (0600) into the support folder.
    @discardableResult
    public func writeSidecarFile(_ url: URL, now: Date = Date()) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        do {
            try sidecarJSON(now: now).write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - What Tara keeps on disk

/// The files that hold each source in the support folder, how many things they hold, and an
/// exact delete. Nothing outside the support folder is ever touched: the vault, Jamie and the
/// agent tools keep their own data.
public struct MemoryFiles: Sendable {
    public var support: URL

    public init(support: URL) { self.support = support }

    public var privacyFile: URL { support.appending(path: "privacy.json") }
    public var meetingsFolder: URL { support.appending(path: "memory") }
    public var meetingFeed: URL { support.appending(path: "Meeting-Agent.md") }
    public var captureQueue: URL { support.appending(path: "capture-queue.jsonl") }
    public var connectorsFolder: URL { support.appending(path: "connectors") }
    /// Today's calendar for Tara (written by the app; counts as a meeting source).
    public var calendarSnapshot: URL { connectorsFolder.appending(path: "calendar.json") }
    /// Scripts that reopen a past agent session.
    public var resumeFolder: URL { support.appending(path: "resume") }

    /// The files of a source as they are now.
    public func files(for source: MemorySource) -> [URL] {
        let fm = FileManager.default
        func listing(_ folder: URL, _ keep: (URL) -> Bool) -> [URL] {
            ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).filter(keep)
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        switch source {
        case .meetings:
            // The Jamie sync state stays: a deleted meeting doesn't come back with the next sync.
            return listing(meetingsFolder) { $0.pathExtension == "json" }
                + [meetingFeed, calendarSnapshot].filter { fm.fileExists(atPath: $0.path) }
        case .captures:
            return fm.fileExists(atPath: captureQueue.path) ? [captureQueue] : []
        case .notes:
            return listing(connectorsFolder) { $0.pathExtension == "json" && $0.lastPathComponent != calendarSnapshot.lastPathComponent }
        case .clipboard:
            return []
        case .sessions:
            return listing(resumeFolder) { $0.pathExtension == "command" }
        }
    }

    /// How many things a source holds: meetings, captures, snapshots, scripts.
    public func count(_ source: MemorySource) -> Int {
        switch source {
        case .meetings:
            ((try? FileManager.default.contentsOfDirectory(atPath: meetingsFolder.path)) ?? []).filter { $0.hasSuffix(".json") }.count
        case .captures:
            ((try? String(contentsOf: captureQueue, encoding: .utf8)) ?? "")
                .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        default: files(for: source).count
        }
    }

    /// Deletes what a source holds; returns the files that are gone. A file that can't be
    /// removed stays in the list's complement, so the caller can say so.
    @discardableResult
    public func forget(_ source: MemorySource) -> [URL] {
        files(for: source).filter { (try? FileManager.default.removeItem(at: $0)) != nil }
    }
}

// MARK: - Today's calendar for Tara

/// One event of today, as the app writes it to `connectors/calendar.json`.
public struct CalendarSnapshotEvent: Equatable, Sendable {
    public var title: String
    public var start: Date
    public var end: Date
    public var location: String?
    public var attendees: [String]
    public var link: String?

    public init(title: String, start: Date, end: Date, location: String? = nil, attendees: [String] = [], link: String? = nil) {
        self.title = title
        self.start = start
        self.end = end
        self.location = location
        self.attendees = attendees
        self.link = link
    }
}

public enum CalendarSnapshot {
    /// `{"name": "Calendar", "updated": …, "today": [{"title", "date", "end", "location", "attendees", "url"}]}`:
    /// the shape the sidecar's connector reader turns into items (`agent/connectors.py`).
    /// Times in the Mac's time zone with its offset, so "10:00" reads as the user's 10:00.
    public static func json(_ events: [CalendarSnapshotEvent], now: Date, timeZone: TimeZone = .current) -> Data {
        let iso = ISO8601DateFormatter()
        iso.timeZone = timeZone
        let items: [[String: Any]] = events.map { event in
            var item: [String: Any] = ["title": event.title, "date": iso.string(from: event.start), "end": iso.string(from: event.end)]
            var details = ["until " + iso.string(from: event.end)]
            if let location = event.location, !location.isEmpty {
                item["location"] = location
                details.append(location)
            }
            if !event.attendees.isEmpty {
                item["attendees"] = event.attendees.joined(separator: ", ")
                details.append("with " + event.attendees.joined(separator: ", "))
            }
            // One line the sidecar's connector reader takes as the item's text.
            item["description"] = details.joined(separator: " · ")
            if let link = event.link { item["url"] = link }
            return item
        }
        let object: [String: Any] = ["name": "Calendar", "updated": iso.string(from: now), "today": items]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
            ?? Data("{}".utf8)
    }

    /// Writes the snapshot (0600) when the meetings source may record now; otherwise nothing is
    /// written and an existing snapshot stays as it was. Returns whether it wrote.
    @discardableResult
    public static func write(_ events: [CalendarSnapshotEvent], to url: URL, privacy: MemoryPrivacy, now: Date = Date(),
                             timeZone: TimeZone = .current) -> Bool {
        guard privacy.records(.meetings, at: now) else { return false }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        do {
            try json(events, now: now, timeZone: timeZone).write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }
}
