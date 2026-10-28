import Foundation

/// Quick notes as plain Markdown files, one per note, in a folder (the app's own, or one the user
/// picks, such as a vault folder). The file is named after the note's first line once the user
/// moves on; until then it keeps a dated placeholder name.
public enum NoteNaming {
    public static let fileExtension = "md"

    /// The first line with text, without Markdown heading marks, at most 60 characters; "" when empty.
    public static func title(of text: String) -> String {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            while trimmed.hasPrefix("#") { trimmed.removeFirst() }
            trimmed = trimmed.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed.count <= 60 ? trimmed : String(trimmed.prefix(59)) + "…" }
        }
        return ""
    }

    /// The text after the title line, folded into one line, for the list.
    public static func preview(of text: String, limit: Int = 80) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
        while let first = lines.first, first.isEmpty || first.allSatisfy({ $0 == "#" }) { lines.removeFirst() }
        if !lines.isEmpty { lines.removeFirst() }
        let folded = lines.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return folded.count <= limit ? folded : String(folded.prefix(limit - 1)) + "…"
    }

    /// "Note 2026-10-28 1432": the name before the note has a title.
    public static func placeholder(created: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: created)
        return String(format: "Note %04d-%02d-%02d %02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0)
    }

    /// A name made by `placeholder(created:)`, maybe with a number ("Note 2026-10-28 1432 2"):
    /// only such files are renamed after their title.
    public static func isPlaceholder(_ name: String) -> Bool {
        name.range(of: #"^Note \d{4}-\d{2}-\d{2} \d{4}( \d+)?$"#, options: .regularExpression) != nil
    }

    /// A file name (without extension) from a title: no path separators or characters that
    /// Finder, iCloud or Obsidian trip over, at most 80 characters; "" when nothing is left.
    public static func safeName(_ title: String) -> String {
        let banned = CharacterSet(charactersIn: "/\\:*?\"<>|#^[]").union(.newlines).union(.controlCharacters)
        let cleaned = title.unicodeScalars.map { banned.contains($0) ? " " : String($0) }.joined()
        var name = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespaces)
        if name.hasSuffix("…") { name.removeLast() }
        return String(name.prefix(80)).trimmingCharacters(in: .whitespaces)
    }

    /// `base`, or `base 2`, `base 3` … when a file of that name exists (compared without case,
    /// as APFS does by default).
    public static func unique(_ base: String, taken: Set<String>) -> String {
        let lowered = Set(taken.map { $0.lowercased() })
        if !lowered.contains(base.lowercased()) { return base }
        var number = 2
        while lowered.contains("\(base) \(number)".lowercased()) { number += 1 }
        return "\(base) \(number)"
    }
}
