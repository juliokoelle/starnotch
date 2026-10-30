import CoreGraphics
import Foundation

/// A note's Markdown as blocks for a reader view, the way Obsidian's reading view shows it:
/// front matter as properties, headings, paragraphs (a single line break stays a break), list
/// items (with their depth and whether they are a done or open task), tables, quotes and
/// callouts, code and rules. Images are left out. Inline marks (bold, links, `[[wiki links]]`)
/// stay in the text for the view to style.
public enum MarkdownBlock: Equatable, Sendable {
    /// The front matter's keys with their values (a list gives several).
    case properties([Property])
    case heading(level: Int, text: String)
    case paragraph(String)
    /// `ordinal` is the item's number in a numbered list; `task` is nil for a plain item.
    case item(text: String, depth: Int, ordinal: Int?, task: Bool?)
    case table(Table)
    case quote(String)
    /// `> [!kind] Title` with the lines under it; `kind` is lowercased.
    case callout(kind: String, title: String, text: String)
    case code(String)
    case rule

    public struct Property: Equatable, Sendable {
        public var key: String
        public var values: [String]

        public init(key: String, values: [String]) {
            self.key = key
            self.values = values
        }
    }

    public struct Table: Equatable, Sendable {
        public enum Alignment: Equatable, Sendable { case leading, center, trailing }

        public var header: [String]
        public var alignments: [Alignment]
        /// Every row has as many cells as the header.
        public var rows: [[String]]

        public init(header: [String], alignments: [Alignment], rows: [[String]]) {
            self.header = header
            self.alignments = alignments
            self.rows = rows
        }

        /// Column widths for a table whose columns would like `ideal` widths in `available`
        /// points: all ideal when they fit; otherwise narrow columns keep theirs and the wide
        /// ones share what is left, none below `minimum` (then the table is wider than
        /// `available` and scrolls).
        public static func columnWidths(ideal: [CGFloat], minimum: CGFloat, available: CGFloat) -> [CGFloat] {
            guard ideal.reduce(0, +) > available else { return ideal }
            var widths = ideal
            var open = Set(ideal.indices)
            var left = available
            // Water-filling: a column below the fair share keeps its width, the rest share.
            while !open.isEmpty {
                let share = left / CGFloat(open.count)
                let small = open.filter { ideal[$0] <= share }
                if small.isEmpty {
                    for column in open { widths[column] = max(min(minimum, ideal[column]), share) }
                    break
                }
                for column in small {
                    widths[column] = ideal[column]
                    left -= ideal[column]
                    open.remove(column)
                }
            }
            return widths
        }
    }

    /// Splits Markdown into blocks; consecutive prose lines join into one paragraph.
    public static func parse(_ text: String) -> [MarkdownBlock] {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            let properties = Self.properties(Array(lines[1..<end]))
            if !properties.isEmpty { blocks.append(.properties(properties)) }
            lines.removeSubrange(0...end)
        }
        var prose: [String] = []
        var quote: [String] = []
        var code: [String]?
        /// Indents of the list items above, for the depth of the next one.
        var indents: [Int] = []

        func flush() {
            if !prose.isEmpty { blocks.append(.paragraph(prose.joined(separator: "\n"))); prose = [] }
            if !quote.isEmpty { blocks.append(Self.quoteOrCallout(quote)); quote = [] }
        }

        var n = 0
        while n < lines.count {
            let raw = lines[n]
            n += 1
            let fence = raw.trimmingCharacters(in: .whitespaces)
            if fence.hasPrefix("```") || fence.hasPrefix("~~~") {
                if let open = code {
                    blocks.append(.code(open.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    indents = []
                    code = []
                }
                continue
            }
            if code != nil { code?.append(raw); continue }
            let line = Self.strippingImages(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                // A line that only held an image leaves no gap.
                if fence.isEmpty { flush() }
                continue
            }
            if let heading = Self.heading(trimmed) { flush(); indents = []; blocks.append(heading); continue }
            if trimmed.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" || $0 == " " }), trimmed.filter({ $0 != " " }).count >= 3 {
                flush()
                indents = []
                blocks.append(.rule)
                continue
            }
            if trimmed.hasPrefix(">") {
                if !prose.isEmpty { flush() }
                var rest = trimmed.dropFirst()
                if rest.first == " " { rest = rest.dropFirst() }
                quote.append(String(rest))
                continue
            }
            if trimmed.contains("|"), n < lines.count, Self.isDelimiterRow(lines[n]) {
                flush()
                indents = []
                let header = Self.cells(trimmed)
                let alignments = Self.cells(lines[n]).map(Self.alignment)
                n += 1
                var rows: [[String]] = []
                while n < lines.count, lines[n].contains("|"), !lines[n].trimmingCharacters(in: .whitespaces).isEmpty {
                    let row = Self.cells(lines[n])
                    rows.append(Array(row.prefix(header.count)) + Array(repeating: "", count: max(0, header.count - row.count)))
                    n += 1
                }
                let aligned = (0..<header.count).map { $0 < alignments.count ? alignments[$0] : .leading }
                blocks.append(.table(Table(header: header, alignments: aligned, rows: rows)))
                continue
            }
            if let (indent, item) = Self.item(line) {
                flush()
                while let last = indents.last, last > indent { indents.removeLast() }
                if indents.last != indent { indents.append(indent) }
                if case .item(let text, _, let ordinal, let task) = item {
                    blocks.append(.item(text: text, depth: min(6, indents.count - 1), ordinal: ordinal, task: task))
                }
                continue
            }
            if !quote.isEmpty { flush() }
            // An indented line under a list item carries on that item.
            if prose.isEmpty, line.first == " " || line.first == "\t", case .item(let text, let depth, let ordinal, let task)? = blocks.last {
                blocks[blocks.count - 1] = .item(text: text + "\n" + trimmed, depth: depth, ordinal: ordinal, task: task)
                continue
            }
            indents = []
            prose.append(trimmed)
        }
        if let open = code { blocks.append(.code(open.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    // MARK: Pieces

    /// `key: value`, `key: [a, b]` and `key:` followed by `- a` lines; quotes come off.
    private static func properties(_ lines: [String]) -> [Property] {
        var out: [Property] = []
        func unquote(_ value: some StringProtocol) -> String {
            var value = value.trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            return value
        }
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("- "), !out.isEmpty {
                out[out.count - 1].values.append(unquote(trimmed.dropFirst(2)))
                continue
            }
            guard line.first != " ", line.first != "\t", let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = unquote(trimmed[..<colon])
            let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            var values: [String]
            if value.hasPrefix("["), value.hasSuffix("]"), !value.hasPrefix("[[") {
                values = value.dropFirst().dropLast().split(separator: ",").map(unquote)
            } else {
                values = value.isEmpty ? [] : [unquote(value)]
            }
            values.removeAll(where: \.isEmpty)
            out.append(Property(key: key, values: values))
        }
        return out.filter { !$0.key.isEmpty && !$0.values.isEmpty }
    }

    private static func quoteOrCallout(_ lines: [String]) -> MarkdownBlock {
        if let first = lines.first, let match = first.wholeMatch(of: #/\[!([A-Za-z-]+)\][+-]?\s*(.*)/#) {
            let kind = String(match.output.1).lowercased()
            let title = String(match.output.2).trimmingCharacters(in: .whitespaces)
            return .callout(kind: kind, title: title.isEmpty ? kind.prefix(1).uppercased() + kind.dropFirst() : title,
                            text: lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return .quote(lines.joined(separator: "\n"))
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return .heading(level: hashes, text: rest.trimmingCharacters(in: .whitespaces))
    }

    /// A list item with the indent it starts at.
    private static func item(_ line: String) -> (Int, MarkdownBlock)? {
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        var rest = Substring(line.drop(while: { $0 == " " || $0 == "\t" }))
        var ordinal: Int?
        if let marker = rest.first, "-*+".contains(marker), rest.dropFirst().first == " " {
            rest = rest.dropFirst(2)
        } else {
            let digits = rest.prefix(while: \.isNumber)
            guard !digits.isEmpty, digits.count < 10 else { return nil }
            let after = rest.dropFirst(digits.count)
            guard let dot = after.first, dot == "." || dot == ")", after.dropFirst().first == " " else { return nil }
            ordinal = Int(digits)
            rest = after.dropFirst(2)
        }
        var task: Bool?
        let box = rest.prefix(4).lowercased()
        if box == "[ ] " || box == "[x] " {
            task = box == "[x] "
            rest = rest.dropFirst(4)
        }
        return (indent, .item(text: rest.trimmingCharacters(in: .whitespaces), depth: 0, ordinal: ordinal, task: task))
    }

    /// `|---|:---:|--:|`, with or without the outer pipes.
    private static func isDelimiterRow(_ line: String) -> Bool {
        let cells = Self.cells(line)
        return !cells.isEmpty && line.contains("-") && cells.allSatisfy { $0.wholeMatch(of: #/:?-+:?/#) != nil }
    }

    private static func alignment(_ delimiter: String) -> Table.Alignment {
        switch (delimiter.hasPrefix(":"), delimiter.hasSuffix(":")) {
        case (true, true): .center
        case (false, true): .trailing
        default: .leading
        }
    }

    /// A table row's cells. A pipe inside `[[link|alias]]` or `code` doesn't split, `\|` is a
    /// pipe, and `<br>` breaks the line.
    static func cells(_ line: String) -> [String] {
        var cells: [String] = []
        var cell = ""
        var wiki = false, code = false
        let chars = Array(line.trimmingCharacters(in: .whitespaces))
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let next = i + 1 < chars.count ? chars[i + 1] : nil
            if c == "\\", next == "|" { cell.append("|"); i += 2; continue }
            if c == "`" { code.toggle() }
            if !code, c == "[", next == "[" { wiki = true }
            if !code, c == "]", next == "]" { wiki = false }
            if c == "|", !wiki, !code {
                cells.append(cell)
                cell = ""
            } else {
                cell.append(c)
            }
            i += 1
        }
        cells.append(cell)
        if chars.first == "|" { cells.removeFirst() }
        if chars.count > 1, chars.last == "|", chars[chars.count - 2] != "\\", !cells.isEmpty { cells.removeLast() }
        return cells.map {
            $0.replacing(#/<br\s*\/?>/#.ignoresCase(), with: "\n").trimmingCharacters(in: .whitespaces)
        }
    }

    /// The line without `![alt](url)` and `![[file.png]]` embeds.
    static func strippingImages(_ line: String) -> String {
        guard line.contains("![") else { return line }
        return line.replacing(#/!\[\[[^\]\n]*\]\]|!\[[^\]\n]*\]\([^)\n]*\)/#, with: "")
    }

    /// `[[folder/Name|shown]]` as a Markdown link to `scheme:Name` showing "shown" (or "Name"),
    /// so a reader can make wiki links clickable. Other text is left alone.
    public static func linkingWikiLinks(_ text: String, scheme: String) -> String {
        text.replacing(#/\[\[([^\]\|\n]+)(?:\|([^\]\n]*))?\]\]/#) { match in
            let target = String(match.output.1)
            let page = target.split(separator: "#").first.map { ($0 as NSString).lastPathComponent } ?? target
            let shown = match.output.2.map(String.init).flatMap { $0.isEmpty ? nil : $0 } ?? page
            let encoded = page.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? page
            return "[\(shown)](\(scheme):\(encoded))"
        }
    }
}
