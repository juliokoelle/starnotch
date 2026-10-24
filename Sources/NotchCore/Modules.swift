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

    public var title: String {
        switch self {
        case .agents: "Agents"
        case .today: "Today"
        case .dictation: "Dictate"
        case .calendar: "Next"
        case .nowPlaying: "Now playing"
        case .system: "System"
        case .meeting: "Meeting"
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
        var rank: [ModuleKind: Int] = [:]
        for (index, kind) in order.enumerated() where rank[kind] == nil { rank[kind] = index }
        return kinds.enumerated()
            .sorted { (rank[$0.element] ?? order.count + $0.offset, $0.offset) < (rank[$1.element] ?? order.count + $1.offset, $1.offset) }
            .map(\.element)
    }

    /// The full order to save after the visible tabs were rearranged to `visible`: hidden
    /// modules keep their place relative to each other, after the visible ones.
    public static func saved(visible: [ModuleKind], previous: [ModuleKind]) -> [ModuleKind] {
        sorted(ModuleKind.allCases, by: visible + sorted(ModuleKind.allCases, by: previous))
    }
}
