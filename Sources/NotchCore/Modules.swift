/// The built-in modules of the notch. Each wheel slot holds a module or, optionally, a
/// third-party notch app (the original switcher behavior).
public enum ModuleKind: String, Codable, CaseIterable, Sendable {
    case agents, today, dictation, calendar
    /// Design preview only (`--preview`), not offered in Settings yet.
    case nowPlaying
    /// CPU, GPU, memory and the apps behind them.
    case system

    public var title: String {
        switch self {
        case .agents: "Agents"
        case .today: "Today"
        case .dictation: "Dictate"
        case .calendar: "Next"
        case .nowPlaying: "Now playing"
        case .system: "System"
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
