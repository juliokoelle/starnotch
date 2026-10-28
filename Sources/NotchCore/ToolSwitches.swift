/// The small tools inside or beside the tabs, each with its own switch in the Tools gallery.
public enum ToolFeature: String, Codable, CaseIterable, Sendable {
    case clipboard, timers, shelf, imageConverter, keepAwake, quickCapture
    // Media strand: synced lyrics (LRCLIB), the lyric line on hover, volume per app.
    case lyrics, lyricsOnHover, appVolume

    /// The tab it lives in; nil for tools outside the tabs (the menu, a shortcut, the plus button).
    public var module: ModuleKind? {
        switch self {
        case .clipboard, .timers, .shelf, .imageConverter: .tools
        case .keepAwake, .quickCapture: nil
        case .lyrics, .lyricsOnHover, .appVolume: .nowPlaying
        }
    }

    /// Works only with this other tool on (the converter acts on the shelf's files, the hover
    /// line shows the lyrics' current line).
    public var requires: ToolFeature? {
        switch self {
        case .imageConverter: .shelf
        case .lyricsOnHover: .lyrics
        default: nil
        }
    }

    public var title: String {
        switch self {
        case .clipboard: "Clipboard history"
        case .timers: "Timers"
        case .shelf: "File shelf"
        case .imageConverter: "Image converter"
        case .keepAwake: "Keep awake"
        case .quickCapture: "Quick capture"
        case .lyrics: "Synced lyrics"
        case .lyricsOnHover: "Lyrics on hover"
        case .appVolume: "Volume per app"
        }
    }
}

/// One row of the Tools gallery: a tab of the notch, or a small tool.
public enum ToolItem: Hashable, Sendable {
    case module(ModuleKind)
    case feature(ToolFeature)
}

/// What the Tools gallery switches. Tabs stay in `disabledModules`, the small tools in
/// `disabledFeatures`; the Tools tab itself has no row and shows while one of its tools is on.
/// A fresh install starts with the core on and everything else off; settings saved before the
/// gallery existed keep every tool the user had. The settings also keep which tools existed when
/// they were saved (`known`), so a tool a later version adds starts off for everyone.
public enum ToolSwitches {
    /// On from the start.
    public static let core: [ModuleKind] = [.agents, .calendar, .nowPlaying]

    /// The gallery in page order: the tabs, then the small tools.
    public static let tabs: [ModuleKind] = core + [.meeting, .today, .system, .dictation]
    public static let gallery: [ToolItem] = tabs.map(ToolItem.module) + ToolFeature.allCases.map(ToolItem.feature)

    /// A fresh install: everything but the core is off.
    public static let offModules: [ModuleKind] = ModuleKind.allCases.filter { !core.contains($0) }
    public static let offFeatures: [ToolFeature] = ToolFeature.allCases

    /// Every tab and small tool of this version, as saved in `SwitcherSettings.knownTools`.
    public static var known: [String] {
        ModuleKind.allCases.map { "module.\($0.rawValue)" } + ToolFeature.allCases.map { "feature.\($0.rawValue)" }
    }

    /// Settings from before the stamp (`knownTools`) keep every tool the gallery started with, as
    /// it was then; any tool added since starts off for them too. Frozen: never add to it.
    public static let knownBeforeStamp: [String] = [
        "module.agents", "module.today", "module.dictation", "module.calendar", "module.nowPlaying",
        "module.system", "module.meeting", "module.tools",
        "feature.clipboard", "feature.timers", "feature.shelf", "feature.imageConverter",
        "feature.keepAwake", "feature.quickCapture",
    ]

    /// Settings saved by a version that knew only `known`: what came since starts off.
    public static func switchOffNew(since known: [String], in settings: inout SwitcherSettings) {
        let known = Set(known)
        for kind in ModuleKind.allCases where !known.contains("module.\(kind.rawValue)") { setModule(kind, on: false, in: &settings) }
        for feature in ToolFeature.allCases where !known.contains("feature.\(feature.rawValue)") { disable(feature, in: &settings) }
    }

    public static func isOn(_ item: ToolItem, in settings: SwitcherSettings) -> Bool {
        switch item {
        case .module(let kind): !settings.disabledModules.contains(kind)
        case .feature(let feature): isOn(feature, in: settings)
        }
    }

    public static func isOn(_ feature: ToolFeature, in settings: SwitcherSettings) -> Bool {
        guard !settings.disabledFeatures.contains(feature) else { return false }
        if let module = feature.module, settings.disabledModules.contains(module) { return false }
        return feature.requires.map { isOn($0, in: settings) } ?? true
    }

    public static func set(_ item: ToolItem, on: Bool, in settings: inout SwitcherSettings) {
        switch item {
        case .module(let kind): setModule(kind, on: on, in: &settings)
        case .feature(let feature): set(feature, on: on, in: &settings)
        }
    }

    public static func set(_ feature: ToolFeature, on: Bool, in settings: inout SwitcherSettings) {
        let module = feature.module
        if on {
            if let module, settings.disabledModules.contains(module) {
                // The tab was off as a whole: only this tool comes back, not its neighbours.
                for other in ToolFeature.allCases where other.module == module && other != feature {
                    disable(other, in: &settings)
                }
                setModule(module, on: true, in: &settings)
            }
            settings.disabledFeatures.removeAll { $0 == feature }
            if let required = feature.requires, !isOn(required, in: settings) { set(required, on: true, in: &settings) }
        } else {
            disable(feature, in: &settings)
            // The Tools tab shows while one of its tools is on; a tab with its own content
            // (Music) stays when an extra inside it goes off.
            if let module, module == .tools {
                let anyOn = ToolFeature.allCases.contains { $0.module == module && ownSwitch($0, in: settings) }
                setModule(module, on: anyOn, in: &settings)
            }
        }
    }

    /// The tool's own switch and those of the tools it needs, whatever its tab says.
    private static func ownSwitch(_ feature: ToolFeature, in settings: SwitcherSettings) -> Bool {
        !settings.disabledFeatures.contains(feature) && (feature.requires.map { ownSwitch($0, in: settings) } ?? true)
    }

    private static func disable(_ feature: ToolFeature, in settings: inout SwitcherSettings) {
        if !settings.disabledFeatures.contains(feature) { settings.disabledFeatures.append(feature) }
    }

    private static func setModule(_ kind: ModuleKind, on: Bool, in settings: inout SwitcherSettings) {
        var disabled = settings.disabledModules.filter { $0 != kind }
        if !on { disabled.append(kind) }
        if disabled != settings.disabledModules { settings.disabledModules = disabled }
    }
}

/// How the meeting agent thinks; the app passes it to the agent as `STARNOTCH_BRAIN`.
public enum TaraBrain: String, Codable, CaseIterable, Sendable {
    /// Not chosen yet: the agent picks what it finds.
    case auto
    /// The user's Claude subscription through Claude Code, no API credits.
    case claudeCode = "claude-code"
    /// The user's own Anthropic API key.
    case api
    /// Simple rules, no model.
    case rules
}
