import Foundation

/// Loops from a plain run log: any recurring agent or job that writes one line per run shows in
/// the notch, no package of its own needed.
///
///     2026-10-26 · morning-brief · ok · built for 27.10.
///
/// Configured in config.toml or in Settings › Agents › Loops:
///
///     [connectors.runlog]
///     file = "~/notes/loops/RUNLOG.md"
///     specs = "~/notes/loops"   # optional: <loop>.md each; a "cron m h dom mon dow" in its front matter is the schedule (UTC)
///
/// Dates in the log are the day of the run on this Mac's clock.
public final class RunLogConnector: NotchConnector, JobsProvider, @unchecked Sendable {
    public static let id = "runlog"
    public static let displayName = "Run log"
    /// Settings' choice when config.toml names no file.
    public static let defaultsKey = "runlogFile"

    private let configuredFile: URL?
    private let configuredSpecs: URL?
    private let lock = NSLock()
    private var cache: (key: String, loops: [LoopStatus])?

    public init(config: ConfigSection) {
        configuredFile = config.path("file")
        configuredSpecs = config.path("specs")
    }

    /// config.toml first, else the file picked in Settings.
    public var file: URL? {
        configuredFile ?? UserDefaults.standard.string(forKey: Self.defaultsKey).map { URL(fileURLWithPath: $0) }
    }

    /// The loops' descriptions: the configured folder, else the log's own folder.
    var specs: URL? { configuredSpecs ?? file?.deletingLastPathComponent() }

    public var logURL: URL? { file }
    public var specLinkTitle: String { "Open the loop" }

    public func loops(now: Date) -> [LoopStatus] {
        guard let file, let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let specFiles = specs.map(RunLog.specFiles(in:)) ?? [:]
        // Cheap when nothing changed: the log's and the specs' modification times, and the day.
        let stamp = ([file] + specFiles.values.map(\.url)).map { url in
            "\(url.path):\(Self.mtime(url)?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: "|") + RunLog.day(now)
        lock.lock()
        if let cache, cache.key == stamp { lock.unlock(); return cache.loops }
        lock.unlock()
        let loops = RunLog.loops(runs: RunLog.parse(text), specs: specFiles, now: now)
        lock.lock()
        cache = (stamp, loops)
        lock.unlock()
        return loops
    }

    private static func mtime(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

/// The run log's format and what the notch makes of it.
public enum RunLog {
    public struct Spec: Equatable, Sendable {
        public var url: URL
        public var schedules: [CronSchedule]
    }

    /// Lines `YYYY-MM-DD · loop · status · note`; anything else (headings, prose) is skipped.
    public static func parse(_ text: String) -> [LoopRun] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.components(separatedBy: " · ")
            guard parts.count >= 3 else { return nil }
            let day = parts[0].trimmingCharacters(in: .whitespaces)
            let loop = parts[1].trimmingCharacters(in: .whitespaces)
            guard day.count == 10, day.dropFirst(4).first == "-", Int(day.prefix(4)) != nil,
                  !loop.isEmpty, !loop.contains(" ") else { return nil }
            let status = LoopRun.Status(rawValue: parts[2].trimmingCharacters(in: .whitespaces).lowercased()) ?? .unknown
            let note = parts.dropFirst(3).joined(separator: " · ").trimmingCharacters(in: .whitespaces)
            return LoopRun(day: day, loop: loop, status: status, note: note)
        }
    }

    /// `<loop>.md` files in a folder with the cron expressions in their front matter.
    public static func specFiles(in folder: URL) -> [String: Spec] {
        var result: [String: Spec] = [:]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "md" {
            let name = url.deletingPathExtension().lastPathComponent
            guard name.uppercased() != name, let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            result[name] = Spec(url: url, schedules: schedules(inFrontMatter: text))
        }
        return result
    }

    /// Every "cron m h dom mon dow" in the front matter (between the first two `---` lines).
    public static func schedules(inFrontMatter text: String) -> [CronSchedule] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return [] }
        let front = lines[1..<end].joined(separator: "\n")
        // A field is a list of numbers, ranges, steps or *; a comma after the last field is prose.
        let field = #"[0-9*/\-]+(?:,[0-9*/\-]+)*"#
        let five = "\(field) \(field) \(field) \(field) \(field)"
        let range = NSRange(front.startIndex..., in: front)
        func captures(_ pattern: String) -> [[String]] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
            return regex.matches(in: front, range: range).map { match in
                (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: front).map { String(front[$0]) } }
            }
        }
        // "cron 30 4,12,20 * * *", then "(0 5 * * 0)", then "täglich 03:30 UTC" / "daily 03:30 UTC".
        for pattern in ["cron (\(five))", "\\((\(five))\\)"] {
            let found = captures(pattern).compactMap { $0.first.flatMap(CronSchedule.init) }
            if !found.isEmpty { return found }
        }
        return captures(#"(?:täglich|daily)\s+(\d{1,2}):(\d{2})\s*UTC"#).prefix(1).compactMap { parts in
            guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
            return CronSchedule("\(minute) \(hour) * * *")
        }
    }

    /// One status per loop: the loops with a description and every loop that ever logged a run.
    public static func loops(runs: [LoopRun], specs: [String: Spec], now: Date) -> [LoopStatus] {
        let names = Set(specs.keys).union(runs.map(\.loop)).sorted()
        let today = day(now), yesterday = day(now.addingTimeInterval(-86_400))
        let dayStart = Calendar.current.startOfDay(for: now)
        return names.map { name in
            let own = runs.filter { $0.loop == name }
            let schedules = specs[name]?.schedules ?? []
            let ranToday = own.contains { $0.day == today }
            let ranRecently = ranToday || own.contains { $0.day == yesterday }
            return LoopStatus(
                name: name,
                last: own.last,
                nextRun: schedules.compactMap { $0.next(after: now) }.min(),
                isLate: !schedules.isEmpty && !ranRecently,
                history: Array(own.suffix(14)),
                slots: schedules.isEmpty ? [] : LoopTimeline.today(schedules: schedules, entries: own.filter { $0.day == today },
                                                                   dayStart: dayStart, now: now),
                specURL: specs[name]?.url)
        }
    }

    /// `YYYY-MM-DD` on this Mac's clock: a log line carries the day of the run where it ran.
    public static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
