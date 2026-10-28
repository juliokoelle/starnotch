import AppKit
import NotchCore
import Observation
import SwiftUI

extension Notification.Name {
    /// "Ask Tara" from the palette, with what was typed in `userInfo["text"]` (may be empty).
    /// Posted by the app's palette wiring; whatever answers Tara's questions observes it.
    static let starnotchAskTara = Notification.Name("StarnotchAskTara")
}

/// Something to find in the command palette: a tab, a session, an event, a tool action.
struct PaletteItem: Identifiable {
    enum Kind: String {
        case tab = "Tab", session = "Session", loop = "Loop", event = "Event", tool = "Tool"
        case clipboard = "Clipboard", file = "Shelf", music = "Music", settings = "Settings", action = "Action"
    }

    /// Stable across openings ("session:<id>"): usage is counted by it.
    var id: String
    var title: String
    var subtitle: String?
    var symbol: String
    var kind: Kind
    /// Other words it answers to; they match, but aren't highlighted.
    var keywords: [String] = []
    /// The provider's sense of what matters now, 0 to 1.
    var priority: Double = 0
    /// A status tint for the symbol (a session waiting, a failed loop); otherwise neutral.
    var tint: Color?
    /// What ⌘↵ does, as a short verb phrase ("Open folder").
    var secondaryTitle: String?
    var perform: () -> Void
    var secondary: (() -> Void)?
}

/// What the palette offers a provider: moving the island, without knowing the controller.
@MainActor
struct PaletteContext {
    /// Opens the panel on a module, as a wheel pick does (Dictate starts dictation).
    var show: (ModuleKind) -> Void
}

/// Adds items to the palette. The palette asks every shown module that conforms, plus the
/// app's own providers, each time it opens: a new module plugs in by conforming, nothing else.
@MainActor
protocol PaletteProvider: AnyObject {
    func paletteItems(_ context: PaletteContext) -> [PaletteItem]
}

/// A provider made of a closure (the app's own items: settings, setup pages).
@MainActor
final class ClosurePaletteProvider: PaletteProvider {
    private let items: (PaletteContext) -> [PaletteItem]
    init(_ items: @escaping (PaletteContext) -> [PaletteItem]) { self.items = items }
    func paletteItems(_ context: PaletteContext) -> [PaletteItem] { items(context) }
}

/// Where the palette's items come from and what it remembers between openings (usage).
@MainActor
final class PaletteSources {
    /// Providers besides the modules.
    var providers: [any PaletteProvider] = []
    /// Ask Tara with what was typed; the item shows only while this is set.
    var askTara: ((String) -> Void)?
    /// Usage is saved unless previews or sample data run.
    var persists = true
    private static let key = "palette.usage"
    private(set) lazy var usage: PaletteUsage = load()

    func record(_ id: String) {
        usage.record(id, at: Date())
        guard persists, let data = try? JSONEncoder().encode(usage) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    private func load() -> PaletteUsage {
        guard persists, let data = UserDefaults.standard.data(forKey: Self.key),
              let usage = try? JSONDecoder().decode(PaletteUsage.self, from: data) else { return PaletteUsage() }
        return usage
    }
}

/// One opening of the palette: the items gathered when it opened, the query, the selection.
@MainActor
@Observable
final class CommandPalette {
    struct Row: Identifiable {
        var item: PaletteItem
        var highlights: [Int]
        var id: String { item.id }
    }

    var query = "" {
        didSet { if query != oldValue { refilter() } }
    }
    private(set) var rows: [Row] = []
    /// Index into `rows`.
    var selection = 0
    var selected: Row? { rows.indices.contains(selection) ? rows[selection] : nil }

    @ObservationIgnored private let items: [PaletteItem]
    @ObservationIgnored private let usage: PaletteUsage
    /// Items made from the query (ask Tara, capture it), always last.
    @ObservationIgnored private let fallbacks: (String) -> [PaletteItem]

    init(items: [PaletteItem], usage: PaletteUsage, fallbacks: @escaping (String) -> [PaletteItem] = { _ in [] }) {
        // The first provider wins a duplicate id.
        var seen = Set<String>()
        self.items = items.filter { seen.insert($0.id).inserted }
        self.usage = usage
        self.fallbacks = fallbacks
        refilter()
    }

    private func refilter() {
        let candidates = items.map {
            PaletteCandidate(id: $0.id, title: $0.title, keywords: $0.keywords + [$0.subtitle ?? "", Localization.string($0.kind.rawValue)],
                             priority: $0.priority)
        }
        let ranked = PaletteRanking.rank(candidates, query: query, usage: usage, now: Date())
        var rows = ranked.map { Row(item: items[$0.index], highlights: $0.highlights) }
        // Ids stay unique in the list: a fallback whose id an item has already is left out.
        let ids = Set(rows.map(\.id))
        rows += fallbacks(query.trimmingCharacters(in: .whitespaces)).filter { !ids.contains($0.id) }.map { Row(item: $0, highlights: []) }
        self.rows = rows
        selection = 0
    }

    /// ↑ ↓: no wrap-around past the ends, like a menu.
    func move(_ step: Int) {
        guard !rows.isEmpty else { return }
        selection = min(max(selection + step, 0), rows.count - 1)
    }
}

// MARK: - View

struct PaletteView: View {
    @Bindable var palette: CommandPalette
    let notch: CGSize
    let onActivate: (_ index: Int, _ secondary: Bool) -> Void
    @FocusState private var focused: Bool

    /// Row height and how many show without scrolling (the island keeps one height).
    static let rowHeight: CGFloat = 34
    static let visibleRows: CGFloat = 6
    static let fieldHeight: CGFloat = 40

    var body: some View {
        VStack(spacing: 0) {
            // Band beside the notch: the keys for the selected row.
            HStack(spacing: 0) {
                Color.clear.frame(maxWidth: .infinity)
                Color.clear.frame(width: notch.width)
                hints.frame(maxWidth: .infinity)
            }
            .frame(height: notch.height)

            VStack(spacing: 6) {
                field
                list
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .onAppear { focused = true }
    }

    private var hints: some View {
        HStack(spacing: 10) {
            if let secondary = palette.selected?.item.secondaryTitle, palette.selected?.item.secondary != nil {
                Text("⌘↵ ") + Text(LocalizedStringKey(secondary))
            }
            Text("esc")
        }
        .font(Theme.font(11.5))
        .foregroundStyle(Theme.textTertiary)
        .lineLimit(1)
    }

    private var field: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
            TextField("Search tabs, sessions, events and tools", text: $palette.query)
                .textFieldStyle(.plain)
                .font(Theme.font(15))
                .foregroundStyle(Theme.textPrimary)
                .focused($focused)
        }
        .padding(.horizontal, 12)
        .frame(height: Self.fieldHeight)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder private var list: some View {
        if palette.rows.isEmpty {
            Text("No matches")
                .font(Theme.font(12.5))
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(Array(palette.rows.enumerated()), id: \.element.id) { index, row in
                            PaletteRow(row: row, selected: index == palette.selection)
                                .contentShape(Rectangle())
                                .onTapGesture { onActivate(index, NSEvent.modifierFlags.contains(.command)) }
                        }
                    }
                }
                .scrollEdgeFade(bottom: 10)
                // The keyboard moves the selection many times a day: no animation, only keep it in view.
                .onChange(of: palette.selection) { _, _ in
                    if let id = palette.selected?.id { proxy.scrollTo(id) }
                }
                .onChange(of: palette.query) { _, _ in
                    if let id = palette.rows.first?.id { proxy.scrollTo(id, anchor: .top) }
                }
            }
        }
    }
}

private struct PaletteRow: View {
    let row: CommandPalette.Row
    let selected: Bool

    var body: some View {
        let item = row.item
        HStack(spacing: 10) {
            Image(systemName: item.symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(item.tint ?? (selected ? Theme.textPrimary : Theme.textSecondary))
                .frame(width: 24, height: 24)
                .background(Color.white.opacity(selected ? 0.1 : 0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            HStack(spacing: 8) {
                title(item.title, highlights: row.highlights)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(Theme.font(12))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            Text(LocalizedStringKey(item.kind.rawValue))
                .font(Theme.font(11.5))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize()
        }
        .padding(.horizontal, 7)
        .frame(height: PaletteView.rowHeight)
        .background(selected ? Color.white.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    /// The matched characters a step brighter and heavier.
    private func title(_ text: String, highlights: [Int]) -> Text {
        var attributed = AttributedString()
        let marks = Set(highlights)
        for (index, character) in text.enumerated() {
            var piece = AttributedString(String(character))
            let hit = marks.contains(index)
            piece.font = Theme.font(13, hit ? .semibold : .medium)
            piece.foregroundColor = hit ? Theme.textPrimary : Theme.textBody
            attributed += piece
        }
        return Text(attributed)
    }
}
