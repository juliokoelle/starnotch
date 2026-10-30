import AppKit
import NotchCore
import SwiftUI

/// A note's Markdown as a quiet reader, close to Obsidian's reading view: front matter as a
/// small properties block, headings by size and weight, paragraphs, nested lists and tasks,
/// tables, quotes and callouts, code, with bold, italics, inline code and links styled.
/// `[[wiki links]]` read as links in the accent and open the node they name (the side panel
/// handles their links). Images are left out.
struct MarkdownView: View {
    let text: String
    /// Long notes stop after this many blocks.
    var limit = 150
    /// Type size relative to the memory map's reader (the notch's cards read smaller).
    var scale: CGFloat = 1

    static let wikiScheme = "starnotch-wiki"
    static let bodySize: CGFloat = 13.5

    var body: some View {
        let blocks = MarkdownBlock.parse(text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.prefix(limit).enumerated()), id: \.offset) { index, block in
                view(block, first: index == 0)
            }
        }
        .tint(TaraAccent.current)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func view(_ block: MarkdownBlock, first: Bool) -> some View {
        switch block {
        case .properties(let properties):
            MarkdownProperties(properties: properties)
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(.system(size: Self.headingSize(level) * scale, weight: level == 1 ? .bold : .semibold))
                .foregroundStyle(level >= 5 ? Theme.textSecondary : Theme.textPrimary)
                .lineSpacing(2)
                .padding(.top, first ? 0 : level <= 2 ? 10 : 5)
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph(let text):
            Text(Self.inline(text))
                .font(.system(size: Self.bodySize * scale))
                .foregroundStyle(Theme.textBody)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        case .item(let text, let depth, let ordinal, let task):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Group {
                    if let task {
                        Image(systemName: task ? "checkmark.square.fill" : "square")
                            .font(.system(size: 11.5 * scale))
                            .foregroundStyle(task ? TaraAccent.current : Theme.textTertiary)
                    } else if let ordinal {
                        Text("\(ordinal).").font(.system(size: (Self.bodySize - 0.5) * scale)).foregroundStyle(Theme.textTertiary).monospacedDigit()
                    } else if depth == 0 {
                        Circle().fill(Theme.textTertiary).frame(width: 4.5, height: 4.5).offset(y: -2.5)
                    } else {
                        Circle().strokeBorder(Theme.textTertiary, lineWidth: 1).frame(width: 5, height: 5).offset(y: -2.5)
                    }
                }
                .frame(minWidth: 12, alignment: .leading)
                Text(Self.inline(text))
                    .font(.system(size: Self.bodySize * scale))
                    .foregroundStyle(task == true ? Theme.textSecondary : Theme.textBody)
                    .strikethrough(task == true, color: Theme.textTertiary)
                    .lineSpacing(3.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * 18)
            .padding(.top, -4)
        case .table(let table):
            MarkdownTable(table: table)
        case .quote(let text):
            Text(Self.inline(text))
                .font(.system(size: Self.bodySize * scale))
                .foregroundStyle(Theme.textSecondary)
                .lineSpacing(3.5)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(Color.white.opacity(0.16)).frame(width: 2) }
        case .callout(let kind, let title, let text):
            MarkdownCallout(kind: kind, title: title, text: text)
        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: code)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textBody)
                    .lineSpacing(2.5)
                    .fixedSize()
                    .padding(10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        case .rule:
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.vertical, 4)
        }
    }

    static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 20
        case 2: 17
        case 3: 15
        case 4: 14
        default: 13.5
        }
    }

    /// Bold, italics, code and links inside a line; wiki links become links to the node; tags
    /// and anything Markdown can't read stay as they are. Line breaks stay.
    static func inline(_ text: String) -> AttributedString {
        let linked = MarkdownBlock.linkingWikiLinks(text, scheme: wikiScheme)
        guard var styled = try? AttributedString(markdown: linked, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                                                  failurePolicy: .returnPartiallyParsedIfPossible)) else {
            return AttributedString(text)
        }
        for run in styled.runs {
            if run.link != nil {
                styled[run.range].foregroundColor = TaraAccent.current
            }
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                styled[run.range].font = .system(size: 12, design: .monospaced)
                styled[run.range].backgroundColor = Color.white.opacity(0.07)
            }
        }
        return styled
    }
}

/// Front matter as Obsidian shows it: one quiet row per key, a list's values as small chips.
private struct MarkdownProperties: View {
    let properties: [MarkdownBlock.Property]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(properties.enumerated()), id: \.offset) { _, property in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: property.key)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .frame(width: 88, alignment: .leading)
                    if property.values.count == 1 {
                        Text(MarkdownView.inline(property.values[0]))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textBody)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        FlowLayout(spacing: 4) {
                            ForEach(Array(property.values.enumerated()), id: \.offset) { _, value in
                                Text(MarkdownView.inline(value))
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Theme.textBody)
                                    .lineLimit(1)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Color.white.opacity(0.07), in: Capsule())
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(0.06)))
    }
}

/// A table with a header row and its columns' alignment. Columns fit the panel's width (the
/// long ones wrap); when even their narrowest doesn't fit, the table scrolls sideways.
private struct MarkdownTable: View {
    let table: MarkdownBlock.Table
    @State private var available: CGFloat = 0

    static let size: CGFloat = 12.5
    static let padding: CGFloat = 9

    var body: some View {
        let widths = columnWidths
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(table.header.indices, id: \.self) { column in
                        cell(table.header[column], column: column, width: widths[column], header: true)
                    }
                }
                ForEach(table.rows.indices, id: \.self) { row in
                    Rectangle().fill(Color.white.opacity(row == 0 ? 0.16 : 0.06)).frame(height: 1)
                        .gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(table.header.indices, id: \.self) { column in
                            cell(table.rows[row][column], column: column, width: widths[column], header: false)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
            .padding(.bottom, 1)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 }
    }

    private func cell(_ text: String, column: Int, width: CGFloat, header: Bool) -> some View {
        let alignment = table.alignments[column]
        return Text(MarkdownView.inline(text))
            .font(.system(size: Self.size, weight: header ? .semibold : .regular))
            .foregroundStyle(header ? Theme.textPrimary : Theme.textBody)
            .multilineTextAlignment(alignment == .center ? .center : alignment == .trailing ? .trailing : .leading)
            .lineSpacing(2.5)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Self.padding)
            .padding(.vertical, 6)
            .frame(width: width, alignment: alignment == .center ? .center : alignment == .trailing ? .trailing : .leading)
    }

    /// Each column as wide as its longest line (at most 420), fitted to the width there is.
    private var columnWidths: [CGFloat] {
        func width(_ cell: String, weight: NSFont.Weight) -> CGFloat {
            let font = NSFont.systemFont(ofSize: Self.size, weight: weight)
            return cell.split(separator: "\n").map { line in
                (String(MarkdownView.inline(String(line)).characters) as NSString).size(withAttributes: [.font: font]).width
            }.max() ?? 0
        }
        let ideal = table.header.indices.map { column in
            let widest = max(width(table.header[column], weight: .semibold),
                             table.rows.map { width($0[column], weight: .regular) }.max() ?? 0)
            return min(420, ceil(widest) + 2 * Self.padding + 2)
        }
        guard available > 0 else { return ideal }
        return MarkdownBlock.Table.columnWidths(ideal: ideal, minimum: 110, available: available - 1)
    }
}

/// `> [!note] Title` as a tinted box with the kind's icon and colour.
private struct MarkdownCallout: View {
    let kind: String
    let title: String
    let text: String

    private var style: (symbol: String, color: Color) {
        switch kind {
        case "tip", "hint", "important", "success", "check", "done": ("checkmark.circle", Color(hex: 0x6CC2B0))
        case "question", "help", "faq": ("questionmark.circle", Color(hex: 0xE2B866))
        case "warning", "caution", "attention": ("exclamationmark.triangle", Color(hex: 0xE2B866))
        case "failure", "fail", "missing", "danger", "error", "bug": ("xmark.octagon", Color(hex: 0xE57F6C))
        case "example": ("list.bullet", Color(hex: 0x9D8DF1))
        case "quote", "cite": ("quote.opening", Color(hex: 0xB4B4B8))
        case "todo": ("checklist", TaraAccent.current)
        case "abstract", "summary", "tldr": ("doc.text", TaraAccent.current)
        default: ("info.circle", TaraAccent.current)
        }
    }

    var body: some View {
        let style = style
        VStack(alignment: .leading, spacing: 5) {
            Label {
                Text(MarkdownView.inline(title)).font(.system(size: 13, weight: .semibold))
            } icon: {
                Image(systemName: style.symbol).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(style.color)
            if !text.isEmpty {
                Text(MarkdownView.inline(text))
                    .font(.system(size: MarkdownView.bodySize))
                    .foregroundStyle(Theme.textBody)
                    .lineSpacing(3.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.color.opacity(0.09), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 6, style: .continuous)
                .fill(style.color.opacity(0.7)).frame(width: 2.5)
        }
    }
}

/// Lines of views that wrap at the available width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [(items: [Int], y: CGFloat, width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], y: CGFloat, width: CGFloat, height: CGFloat)] = []
        var current: (items: [Int], y: CGFloat, width: CGFloat, height: CGFloat) = ([], 0, 0, 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !current.items.isEmpty && current.width + spacing + size.width > width {
                rows.append(current)
                current = ([], current.y + current.height + spacing, 0, 0)
            }
            current.width += (current.items.isEmpty ? 0 : spacing) + size.width
            current.height = max(current.height, size.height)
            current.items.append(index)
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}
