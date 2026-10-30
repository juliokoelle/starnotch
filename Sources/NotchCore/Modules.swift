import CoreGraphics

/// The built-in modules of the notch. Each wheel slot holds a module or, optionally, a
/// third-party notch app (the original switcher behavior).
public enum ModuleKind: String, Codable, CaseIterable, Sendable {
    case agents, today, dictation, calendar
    /// Design preview only (`--preview`), not offered in Settings yet.
    case nowPlaying
    /// CPU, GPU, memory and the apps behind them.
    case system
    /// The meeting agent (agent/): live contradictions, questions, commitments and prep cards.
    case meeting
    /// Clipboard history, focus timer, file shelf.
    case tools

    public var title: String {
        switch self {
        case .agents: "Agents"
        case .today: "Today"
        case .dictation: "Dictate"
        case .calendar: "Next"
        case .nowPlaying: "Now playing"
        case .system: "System"
        case .meeting: "Meeting"
        case .tools: "Tools"
        }
    }

    /// Modules Settings offers; preview modules stay out until they ship.
    public static var selectable: [ModuleKind] { allCases.filter { $0 != .nowPlaying } }

    /// Default wheel layout: agents on top, dictation right, next meeting at the bottom, today left.
    public static let defaultLayout: [ModuleKind?] = [.agents, .dictation, .calendar, .today]
}

public enum SlotItem: Equatable, Sendable {
    case module(ModuleKind)
    case app(SlotApp)
}

/// The user's tab order (Settings and the island's tab strip share it).
public enum ModuleOrder {
    /// `kinds` in `order`'s sequence (first mention wins); kinds `order` doesn't name follow in
    /// their own sequence.
    public static func sorted(_ kinds: [ModuleKind], by order: [ModuleKind]) -> [ModuleKind] {
        ordered(kinds, by: order)
    }

    /// The same for any tabs, e.g. the small tools'.
    public static func ordered<Kind: Hashable>(_ kinds: [Kind], by order: [Kind]) -> [Kind] {
        var rank: [Kind: Int] = [:]
        for (index, kind) in order.enumerated() where rank[kind] == nil { rank[kind] = index }
        return kinds.enumerated()
            .sorted { (rank[$0.element] ?? order.count + $0.offset, $0.offset) < (rank[$1.element] ?? order.count + $1.offset, $1.offset) }
            .map(\.element)
    }

    /// The full order to save after the visible tabs were rearranged to `visible`: hidden
    /// modules keep their place relative to each other, after the visible ones.
    public static func saved(visible: [ModuleKind], previous: [ModuleKind]) -> [ModuleKind] {
        saved(visible: visible, previous: previous, all: ModuleKind.allCases)
    }

    /// The same for any tabs, e.g. the small tools' (`all` in their built-in order).
    public static func saved<Kind: Hashable>(visible: [Kind], previous: [Kind], all: [Kind]) -> [Kind] {
        ordered(all, by: visible + ordered(all, by: previous))
    }
}

/// The two sizes of the open island. A module picks a class, never numbers: content tabs (agents,
/// calendar, system, meeting, today) open large; the quick ones (music, dictation, tools) open
/// compact, so a glance doesn't cover half the screen. Switching tabs springs between the two.
public enum PanelSize: String, Sendable, CaseIterable {
    case large, compact

    /// Preferred width of the panel (the open island narrows or widens a little around it to end
    /// between two menu bar icons).
    public var width: CGFloat {
        switch self {
        case .large: 640
        case .compact: 520
        }
    }

    /// Height of the panel body under the tab strip.
    public var height: CGFloat {
        switch self {
        case .large: 280
        case .compact: 150
        }
    }

    /// How far the island may narrow or widen around `width` to fit the menu bar icons. The
    /// compact panel only widens: its header already splits the tabs around the notch, and any
    /// narrower the tabs right of the notch would run over the status.
    public var widthRange: ClosedRange<CGFloat> {
        switch self {
        case .large: width - 48 ... width + 24
        case .compact: width ... width + 24
        }
    }
}

extension ModuleKind {
    /// The panel size of each built-in module; content modules (and new ones unless they say
    /// otherwise) open large.
    public var panelSize: PanelSize {
        switch self {
        case .nowPlaying, .dictation, .tools: .compact
        default: .large
        }
    }
}
