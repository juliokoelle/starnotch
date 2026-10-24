import NotchCore

/// SF Symbols for modules where no module instance is at hand (wheel, settings).
enum ModuleSymbols {
    static func symbol(_ kind: ModuleKind) -> String {
        switch kind {
        case .agents: "circle.grid.2x2"
        case .today: "checklist"
        case .dictation: "mic"
        case .calendar: "calendar"
        case .nowPlaying: "music.note"
        case .system: "gauge.with.dots.needle.50percent"
        case .meeting: "person.2.wave.2"
        }
    }
}
