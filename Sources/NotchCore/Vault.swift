import Foundation

// A notes vault (an Obsidian vault or any folder of Markdown files): its open tasks, the daily
// note, and where things are. Pure functions over text; `VaultConnector` does the file work.

/// One open Markdown task, e.g. `- [ ] Send the deck 📅 2026-10-28 #work`.
public struct VaultTask: Equatable, Sendable, Codable {
    /// Stable while the line stays as it is: the file, the line's text and which copy of it.
    public var id: String
    /// The file, relative to the vault folder.
    public var file: String
    /// 0-based line number when it was read.
    public var line: Int
    /// The line exactly as read: ticking it off must find this text again.
    public var raw: String
    public var title: String
    /// The rest of the line after a bold title, cleaned.
    public var detail: String
    /// `YYYY-MM-DD`.
    public var due: String?
    /// `HH:MM`, when the due date has a time.
    public var time: String?
    /// `#tags` and `@contexts`, without the sign.
    public var tags: [String]
    /// The heading it sits under.
    public var section: String
    /// Indented lines under it.
    public var notes: [String]
    /// A repeating task (🔁): the notch leaves ticking it off to the notes app, which plans the next one.
    public var repeats: Bool

    public init(id: String, file: String, line: Int, raw: String, title: String, detail: String = "",
                due: String? = nil, time: String? = nil, tags: [String] = [], section: String = "",
                notes: [String] = [], repeats: Bool = false) {
        self.id = id
        self.file = file
        self.line = line
        self.raw = raw
        self.title = title
        self.detail = detail
        self.due = due
        self.time = time
        self.tags = tags
        self.section = section
        self.notes = notes
        self.repeats = repeats
    }
}

public enum MarkdownTasks {
    /// The open tasks in a Markdown text: `- [ ]`, `* [ ]`, `+ [ ]` or `1. [ ]`, at any indent.
    /// Front matter and code blocks are skipped.
    public static func parse(_ text: String, file: String) -> [VaultTask] {
        var tasks: [VaultTask] = []
        var section = ""
        var seen: [String: Int] = [:]
        var inFence = false
        // The task whose indented lines are being collected, and its indent.
        var open: (index: Int, indent: Int)?
        let lines = text.components(separatedBy: "\n")
        let frontEnd = frontMatterEnd(lines)
        for (number, line) in lines.enumerated() where number >= frontEnd {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle(); open = nil; continue }
            if inFence { continue }
            let indent = indentWidth(line)
            if let heading = heading(trimmed) {
                section = heading.text
                open = nil
                continue
            }
            if let task = checkbox(line) {
                guard task.open else { open = nil; continue }
                let copy = seen[line, default: 0]
                seen[line] = copy + 1
                let parts = Inline.parse(task.body)
                tasks.append(VaultTask(id: "\(file)#\(Hash.fnv(line))-\(copy)", file: file, line: number, raw: line,
                                       title: parts.title, detail: parts.detail, due: parts.due, time: parts.time,
                                       tags: parts.tags, section: section, repeats: parts.repeats))
                open = (tasks.count - 1, indent)
                continue
            }
            guard let current = open else { continue }
            if trimmed.isEmpty { continue }
            guard indent > current.indent else { open = nil; continue }
            if tasks[current.index].notes.count < 4 {
                var note = trimmed
                for marker in ["- ", "* ", "+ "] where note.hasPrefix(marker) { note = String(note.dropFirst(2)) }
                let cleaned = Inline.parse(note)
                let text = [cleaned.title, cleaned.detail].filter { !$0.isEmpty }.joined(separator: " ")
                if !text.isEmpty { tasks[current.index].notes.append(text) }
            }
        }
        return tasks
    }

    /// How many open tasks a text has (an inbox's counter).
    public static func openCount(_ text: String) -> Int {
        text.components(separatedBy: "\n").filter { checkbox($0)?.open == true }.count
    }

    /// The text with `task` ticked off (`- [ ]` becomes `- [x]`), or nil when its line isn't
    /// there exactly once as it was read. Only that line changes; line endings stay as they are.
    public static func completing(_ task: VaultTask, in text: String) -> String? {
        var lines = text.components(separatedBy: "\n")
        let index: Int
        if task.line < lines.count, lines[task.line] == task.raw {
            index = task.line
        } else {
            let hits = lines.indices.filter { lines[$0] == task.raw }
            guard hits.count == 1, let only = hits.first else { return nil }
            index = only
        }
        guard checkbox(lines[index])?.open == true, let box = lines[index].range(of: "[ ]") else { return nil }
        lines[index].replaceSubrange(box, with: "[x]")
        return lines.joined(separator: "\n")
    }

    // MARK: Lines

    struct Checkbox {
        var open: Bool
        var body: String
    }

    /// A list item with a checkbox: `- [ ] body`.
    static func checkbox(_ line: String) -> Checkbox? {
        var rest = Substring(line).drop { $0 == " " || $0 == "\t" }
        if let first = rest.first, "-*+".contains(first) {
            rest = rest.dropFirst()
        } else {
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, digits.count < 10 else { return nil }
            rest = rest.dropFirst(digits.count)
            guard let mark = rest.first, mark == "." || mark == ")" else { return nil }
            rest = rest.dropFirst()
        }
        guard rest.first == " " else { return nil }
        rest = rest.drop { $0 == " " }
        guard rest.count >= 3, rest.first == "[", rest.dropFirst(2).first == "]" else { return nil }
        let state = rest.dropFirst().first!
        guard state == " " || state == "x" || state == "X" else { return nil }
        let body = rest.dropFirst(3)
        guard body.isEmpty || body.first == " " else { return nil }
        let text = body.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return Checkbox(open: state == " ", body: text)
    }

    /// `## Heading` → level and text.
    static func heading(_ trimmed: String) -> (level: Int, text: String)? {
        let hashes = trimmed.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count), trimmed.dropFirst(hashes.count).first == " " else { return nil }
        let text = Inline.parse(String(trimmed.dropFirst(hashes.count))).plain
        return text.isEmpty ? nil : (hashes.count, text)
    }

    /// The index of the first line after the front matter (0 without one).
    static func frontMatterEnd(_ lines: [String]) -> Int {
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return 0 }
        guard let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return 0 }
        return end + 1
    }

    static func indentWidth(_ line: String) -> Int {
        var width = 0
        for character in line {
            if character == " " { width += 1 } else if character == "\t" { width += 4 } else { break }
        }
        return width
    }
}

/// What a task's text says: title, due date, tags; Markdown and plugin fields cleaned away.
enum Inline {
    struct Parts {
        var title: String
        var detail: String
        var due: String?
        var time: String?
        var tags: [String]
        var repeats: Bool
        /// Title and detail as one line.
        var plain: String { [title, detail].filter { !$0.isEmpty }.joined(separator: " ") }
    }

    private static let date = #"(\d{4}-\d{2}-\d{2})"#
    private static let clock = #"(?:[ T](\d{1,2}:\d{2}))?"#
    /// Ways to write a due date: Obsidian Tasks, Dataview, quick capture, TaskPaper.
    private static let duePatterns: [NSRegularExpression] = [
        "📅\\s*\(date)\(clock)",
        "\\[due::\\s*\(date)\(clock)\\s*\\]",
        "\\(due:{0,2}\\s*\(date)\(clock)\\s*\\)",
        "@due\\(\(date)\(clock)\\)",
        "(?<!\\S)due::\\s*\(date)\(clock)",
    ].map(regex)
    private static let removals: [NSRegularExpression] = [
        #"\[[\w-]+::[^\]]*\]"#,                         // [field:: value]
        #"\([\w-]+::[^)]*\)"#,                          // (field:: value)
        #"[⏳🛫➕✅❌]️?\s*\d{4}-\d{2}-\d{2}"#,      // Tasks dates
        #"🔁️?[^📅⏳🛫➕✅⏫🔼🔽🔺⏬#\[]*"#,             // Tasks recurrence
        #"[⏫🔼🔽🔺⏬]️?"#,                          // Tasks priority
        #"\s\^[\w-]+\s*$"#,                             // block id
    ].map(regex)
    private static let tag = regex(#"(?<![\w/&#])[#@]([\p{L}_][\p{L}\p{N}_/-]*)"#)
    private static let wiki = regex(#"!?\[\[([^\]|#]+)(?:#[^\]|]*)?(?:\|([^\]]+))?\]\]"#)
    private static let link = regex(#"!?\[([^\]]*)\]\([^)]*\)"#)
    private static let italic = regex(#"(?<![\w*])\*([^*\n]+)\*(?![\w*])"#)

    static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are literals in this file: a typo is a programming error.
        try! NSRegularExpression(pattern: pattern)
    }

    static func parse(_ body: String) -> Parts {
        var text = body
        var due: String?, time: String?
        for pattern in duePatterns {
            // Back to front, so the ranges stay valid and the first date written wins.
            for match in matches(pattern, in: text).reversed() {
                due = group(match, 1, in: text)
                time = group(match, 2, in: text)
                text = replacing(match.range, in: text, with: " ")
            }
            if due != nil { break }
        }
        let repeats = text.contains("🔁")
        for pattern in removals { text = pattern.stringByReplacingMatches(in: text, range: whole(text), withTemplate: " ") }
        text = text.replacingOccurrences(of: "`", with: "")
        text = replacingWikiLinks(text)
        text = link.stringByReplacingMatches(in: text, range: whole(text), withTemplate: "$1")
        var tags: [String] = []
        for match in matches(tag, in: text).reversed() {
            if let name = group(match, 1, in: text) { tags.insert(name, at: 0) }
            text = replacing(match.range, in: text, with: " ")
        }
        // A bold start is the title; what follows is its detail.
        var title = text.trimmingCharacters(in: .whitespaces)
        var detail = ""
        if title.hasPrefix("**"), let close = title.range(of: "**", range: title.index(title.startIndex, offsetBy: 2)..<title.endIndex) {
            detail = String(title[close.upperBound...])
            title = String(title[title.index(title.startIndex, offsetBy: 2)..<close.lowerBound])
            title = title.trimmingCharacters(in: .whitespaces)
            if title.hasSuffix(":") || (title.hasSuffix(".") && !title.hasSuffix("..")) { title.removeLast() }
        }
        return Parts(title: tidy(title), detail: tidy(detail), due: due, time: time.map(padded), tags: tags, repeats: repeats)
    }

    /// Emphasis marks out, spaces collapsed.
    static func tidy(_ text: String) -> String {
        var text = text
        for mark in ["**", "__", "~~", "=="] { text = text.replacingOccurrences(of: mark, with: "") }
        text = italic.stringByReplacingMatches(in: text, range: whole(text), withTemplate: "$1")
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,;·–-").union(.whitespaces))
    }

    /// `[[folder/Note|alias]]` → alias, `[[folder/Note]]` → Note.
    static func replacingWikiLinks(_ text: String) -> String {
        var text = text
        for match in matches(wiki, in: text).reversed() {
            let target = group(match, 1, in: text) ?? ""
            let shown = group(match, 2, in: text) ?? target.split(separator: "/").last.map(String.init) ?? target
            text = replacing(match.range, in: text, with: shown)
        }
        return text
    }

    private static func padded(_ time: String) -> String { time.count == 4 ? "0" + time : time }
    private static func whole(_ text: String) -> NSRange { NSRange(text.startIndex..., in: text) }
    private static func matches(_ pattern: NSRegularExpression, in text: String) -> [NSTextCheckingResult] {
        pattern.matches(in: text, range: whole(text))
    }
    private static func group(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> String? {
        guard index < match.numberOfRanges, let range = Range(match.range(at: index), in: text) else { return nil }
        return String(text[range])
    }
    private static func replacing(_ range: NSRange, in text: String, with replacement: String) -> String {
        guard let range = Range(range, in: text) else { return text }
        return text.replacingCharacters(in: range, with: replacement)
    }
}

/// A short stable hash for ids (Swift's `Hasher` changes every launch).
enum Hash {
    static func fnv(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }
}

// MARK: Daily notes

public enum DailyNote {
    /// The path of a day's note from a pattern like `Daily/YYYY-MM-DD.md`. `YYYY`, `YY`, `MM`,
    /// `M`, `DD` and `D` are replaced where they stand apart from other letters, so a folder
    /// named "Daily" stays as it is; `[text]` is literal, as in Obsidian's date format.
    public static func path(pattern: String, date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = parts.year ?? 0, month = parts.month ?? 0, day = parts.day ?? 0
        let tokens: [String: String] = [
            "YYYY": String(format: "%04d", year), "YY": String(format: "%02d", year % 100),
            "MM": String(format: "%02d", month), "M": "\(month)",
            "DD": String(format: "%02d", day), "D": "\(day)",
        ]
        let characters = Array(pattern)
        var result = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "[", let close = characters[index...].firstIndex(of: "]") {
                result += String(characters[(index + 1)..<close])
                index = close + 1
                continue
            }
            guard "YMD".contains(character) else { result.append(character); index += 1; continue }
            var end = index
            while end < characters.count, characters[end] == character { end += 1 }
            let run = String(characters[index..<end])
            let before = index > 0 ? characters[index - 1] : " "
            let after = end < characters.count ? characters[end] : " "
            if let value = tokens[run], !before.isLetter, !after.isLetter {
                result += value
            } else {
                result += run
            }
            index = end
        }
        return result
    }

    /// The note's headings, the date heading on top left out when there are others.
    public static func headings(_ text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        var found: [(level: Int, text: String)] = []
        var inFence = false
        for line in lines.dropFirst(MarkdownTasks.frontMatterEnd(lines)) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle(); continue }
            if !inFence, let heading = MarkdownTasks.heading(trimmed) { found.append(heading) }
        }
        let deeper = found.filter { $0.level > 1 }
        return (deeper.isEmpty ? found : deeper).map(\.text)
    }

    /// The note without its front matter, at most `limit` characters.
    public static func body(_ text: String, limit: Int = 4000) -> String {
        let lines = text.components(separatedBy: "\n")
        let body = lines.dropFirst(MarkdownTasks.frontMatterEnd(lines)).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return body.count > limit ? String(body.prefix(limit)) + "…" : body
    }
}

// MARK: Where things are

/// The files of a vault the notch uses, relative to its folder.
public struct VaultLayout: Equatable, Sendable {
    /// A tasks file, or a folder whose Markdown files hold tasks.
    public var tasks: String?
    /// The daily note's path pattern, e.g. `Daily/YYYY-MM-DD.md`.
    public var daily: String?
    /// The file quick capture appends to.
    public var inbox: String?
    /// The loops' run log.
    public var loops: String?

    public init(tasks: String? = nil, daily: String? = nil, inbox: String? = nil, loops: String? = nil) {
        self.tasks = tasks
        self.daily = daily
        self.inbox = inbox
        self.loops = loops
    }
}

public enum VaultDetect {
    static let taskNames: Set<String> = ["tasks", "todo", "todos", "to-do", "open_tasks", "open tasks", "open-tasks", "aufgaben"]
    static let inboxNames: Set<String> = ["inbox", "eingang"]
    static let logNames: Set<String> = ["runlog", "run-log", "run log"]

    /// A sensible first guess from the folder's files: Obsidian's daily notes settings, else the
    /// folder with the most `YYYY-MM-DD.md` notes; a file called Tasks, TODO or Inbox; a run log.
    public static func detect(in folder: URL) -> VaultLayout {
        let files = markdownFiles(in: folder, maxDepth: 3)
        var layout = VaultLayout()
        layout.tasks = shallowest(files) { taskNames.contains($0) }
        layout.inbox = shallowest(files) { inboxNames.contains($0) }
        layout.loops = shallowest(files) { logNames.contains($0) }
        layout.daily = obsidianDaily(in: folder) ?? dailyFromNames(files)
        if layout.tasks == nil, let tasksFolder = folderNamed(taskNames, in: folder) { layout.tasks = tasksFolder }
        return layout
    }

    /// `.obsidian/daily-notes.json`: `{"folder": "Daily", "format": "YYYY-MM-DD"}`.
    static func obsidianDaily(in folder: URL) -> String? {
        let file = folder.appending(path: ".obsidian/daily-notes.json")
        guard let data = try? Data(contentsOf: file),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let format = (json["format"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "YYYY-MM-DD"
        let base = ((json["folder"] as? String) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return (base.isEmpty ? "" : base + "/") + format + ".md"
    }

    /// The folder holding the most notes named like a date.
    static func dailyFromNames(_ files: [String]) -> String? {
        var counts: [String: Int] = [:]
        for file in files {
            let name = (file as NSString).lastPathComponent
            guard name.count == 13, name.hasSuffix(".md"), isDate(String(name.prefix(10))) else { continue }
            counts[(file as NSString).deletingLastPathComponent, default: 0] += 1
        }
        guard let best = counts.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }), best.value >= 2 else { return nil }
        return (best.key.isEmpty ? "" : best.key + "/") + "YYYY-MM-DD.md"
    }

    static func isDate(_ text: String) -> Bool {
        let parts = text.split(separator: "-")
        return parts.count == 3 && parts[0].count == 4 && parts[1].count == 2 && parts[2].count == 2
            && parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    /// The least nested file whose lowercased name (without .md) matches.
    static func shallowest(_ files: [String], _ matches: (String) -> Bool) -> String? {
        files.filter { matches((($0 as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()) }
            .min { lhs, rhs in
                let depth = (lhs.split(separator: "/").count, rhs.split(separator: "/").count)
                return depth.0 == depth.1 ? lhs < rhs : depth.0 < depth.1
            }
    }

    static func folderNamed(_ names: Set<String>, in folder: URL) -> String? {
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return entries.first { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && names.contains(url.lastPathComponent.lowercased())
        }?.lastPathComponent
    }

    /// Markdown files under `folder`, relative, hidden folders skipped; bounded for huge folders.
    public static func markdownFiles(in folder: URL, maxDepth: Int, limit: Int = 20_000) -> [String] {
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var files: [String] = []
        var seen = 0
        for case let url as URL in walker {
            seen += 1
            if seen > limit { break }
            if walker.level > maxDepth { walker.skipDescendants(); continue }
            if url.lastPathComponent == "node_modules" { walker.skipDescendants(); continue }
            guard url.pathExtension.lowercased() == "md" else { continue }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(base + "/") else { continue }
            files.append(String(path.dropFirst(base.count + 1)))
        }
        return files
    }
}

// MARK: For Tara

/// What `VaultConnector` writes to `connectors/vault.json` for Tara's brain.
public struct VaultSnapshot: Codable, Equatable, Sendable {
    public struct DailyNote: Codable, Equatable, Sendable {
        public var path: String
        public var headings: [String]
        /// Without front matter, trimmed.
        public var text: String
    }

    public struct Note: Codable, Equatable, Sendable {
        public var title: String
        public var path: String
        public var modified: Date
    }

    public var version = 1
    public var updated: Date
    /// The vault's folder name.
    public var name: String
    /// `YYYY-MM-DD` on this Mac's clock when written.
    public var today: String
    /// Open tasks: dated ones first by due date, then the rest in file order.
    public var tasks: [VaultTask]
    public var openTasks: Int
    public var dailyNote: DailyNote?
    public var recentNotes: [Note]

    enum CodingKeys: String, CodingKey {
        case version, updated, name, today, tasks, dailyNote = "daily_note", openTasks = "open_tasks", recentNotes = "recent_notes"
    }
}
