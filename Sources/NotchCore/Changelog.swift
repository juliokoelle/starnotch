import Foundation

// CHANGELOG.md, read for the app's What's new: one section per day an update landed (`## 29 October
// 2026`), grouped by theme (`### Dashboard`), one line per change (`- **New:** …`).

public struct ChangelogDay: Equatable, Sendable, Identifiable {
    public struct Group: Equatable, Sendable, Identifiable {
        public var title: String
        public var items: [Item]
        public var id: String { title }
    }

    public struct Item: Equatable, Sendable, Identifiable {
        public var kind: ChangeKind
        /// Markdown (bold and code spans stay for the view to render).
        public var text: String
        public var id: String { kind.rawValue + text }
    }

    /// As written: "29 October 2026".
    public var title: String
    public var groups: [Group]
    public var id: String { title }

    /// The day's date when the title is one ("29 October 2026").
    public var date: Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMMM yyyy"
        return formatter.date(from: title)
    }
}

public enum ChangeKind: String, Sendable, CaseIterable {
    case new = "New", improved = "Improved", fixed = "Fixed", changed = "Changed"
}

public enum Changelog {
    public static let fileName = "CHANGELOG.md"

    /// The days, newest first as the file has them. A line without a known kind counts as a change.
    public static func parse(_ markdown: String) -> [ChangelogDay] {
        var days: [ChangelogDay] = []
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                days.append(ChangelogDay(title: String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces), groups: []))
            } else if line.hasPrefix("### "), !days.isEmpty {
                days[days.count - 1].groups.append(.init(title: String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces), items: []))
            } else if line.hasPrefix("- "), !days.isEmpty {
                if days[days.count - 1].groups.isEmpty { days[days.count - 1].groups.append(.init(title: "", items: [])) }
                let (kind, text) = item(String(line.dropFirst(2)))
                let last = days[days.count - 1].groups.count - 1
                days[days.count - 1].groups[last].items.append(.init(kind: kind, text: text))
            }
        }
        return days.filter { !$0.groups.isEmpty }
    }

    /// `**New:** text` → (.new, "text").
    static func item(_ line: String) -> (ChangeKind, String) {
        for kind in ChangeKind.allCases {
            for prefix in ["**\(kind.rawValue):**", "**\(kind.rawValue)**:", "\(kind.rawValue):"] where line.hasPrefix(prefix) {
                return (kind, String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces))
            }
        }
        return (.changed, line)
    }
}
