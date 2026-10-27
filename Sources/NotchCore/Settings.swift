import Foundation

/// An app assigned to a slot.
public struct SlotApp: Codable, Equatable, Hashable, Sendable {
    public var bundleID: String
    public var name: String
    /// Last known location of the app bundle. Used for the icon and as a launch fallback.
    public var path: String

    public init(bundleID: String, name: String, path: String) {
        self.bundleID = bundleID
        self.name = name
        self.path = path
    }
}

/// When the island shows figures beside the notch at rest.
public enum EarsMode: String, Codable, CaseIterable, Sendable {
    case never
    /// Only when something needs you (default).
    case attention
    /// Whenever a module has something to show (agents at work, music).
    case always

    public var title: String {
        switch self {
        case .never: "Never"
        case .attention: "When it needs me"
        case .always: "Always"
        }
    }
}

/// How long manual Watch mode stays on.
public enum WatchTimer: String, Codable, CaseIterable, Sendable {
    case oneHour, twoHours, untilOff

    public var seconds: Double? {
        switch self {
        case .oneHour: 3600
        case .twoHours: 7200
        case .untilOff: nil
        }
    }

    public var title: String {
        switch self {
        case .oneHour: "1 hour"
        case .twoHours: "2 hours"
        case .untilOff: "Until I turn it off"
        }
    }
}

/// Where the island lives when there are several displays.
public enum IslandDisplay: String, Codable, CaseIterable, Sendable {
    /// The display with a notch, else the main display (a pill at the top center).
    case automatic
    /// Always the main display (the one with the menu bar).
    case main
    /// The display the pointer is on; it moves along at rest.
    case pointer

    public var title: String {
        switch self {
        case .automatic: "Notch"
        case .main: "Main display"
        case .pointer: "With pointer"
        }
    }
}

public struct SwitcherSettings: Codable, Equatable, Sendable {
    public static let slotCount = SlotPosition.allCases.count

    /// Exactly four entries, indexed by `SlotPosition.rawValue`. A slot shows its module if it
    /// has one, otherwise its app.
    public var slots: [SlotApp?]
    /// Built-in module per slot, same indexing as `slots`.
    public var modules: [ModuleKind?]
    /// The slot that was selected last.
    public var activeSlot: SlotPosition?
    /// Force quit slot apps that are still running after `forceQuitTimeout` seconds.
    public var forceQuitEnabled: Bool
    public var forceQuitTimeout: Double
    /// How long the notch has to be held before the wheel opens.
    public var holdDuration: Double
    /// The settings window has opened once to explain the Accessibility permission.
    public var didShowAccessibilityIntro: Bool
    /// Avatar of the main agent (character id from a pack).
    public var mainCharacter: String
    /// Colorway of the main character; `nil` is its default look.
    public var colorway: String?
    /// The localhost status API (`POST 127.0.0.1:47789/status` with a token).
    public var localAPIEnabled: Bool
    /// Character and base colour per project (repo folder name).
    public var projects: [String: ProjectStyle]
    /// What a session's colour means: its performance level (default) or just which session it is.
    public var colourBy: ColourBy
    /// Colorway per performance level (colorway names, e.g. "matte_black").
    public var colourScale: [PerformanceLevel: String]
    /// The first-run page has been shown (older saved settings count as onboarded).
    public var didOnboard: Bool
    /// Which display the island lives on.
    public var islandDisplay: IslandDisplay
    /// Tabs the user switched off (onboarding or Settings › Tools); a fresh install starts with
    /// all but the core off (`ToolSwitches`).
    public var disabledModules: [ModuleKind]
    /// Small tools switched off (clipboard, timers, keep awake …), off on a fresh install.
    public var disabledFeatures: [ToolFeature]
    /// The tabs and small tools this version knows (`ToolSwitches.known`), saved with the switches:
    /// one added later is off on load instead of on.
    public private(set) var knownTools: [String]
    /// How the meeting agent thinks (onboarding or Settings › Meeting agent).
    public var brain: TaraBrain
    /// The open panel stays until a click outside (or Esc), not when the pointer leaves.
    public var keepOpenUntilClick: Bool
    /// Figures beside the notch at rest.
    public var earsMode: EarsMode
    /// Watch mode turns on by itself for fullscreen apps and video.
    public var watchAutomatic: Bool
    /// How long a manually started Watch mode lasts.
    public var watchTimer: WatchTimer
    /// Agent tools switched off in Settings › Providers (`ClaudeCodeProvider.id`, `CodexProvider.id`).
    public var disabledProviders: [String]
    /// Apple Reminders due today show in Today.
    public var remindersInToday: Bool
    /// Tab order, set by dragging a tab in the island (`ModuleOrder`); empty = the built-in order.
    public var moduleOrder: [ModuleKind]

    public init(
        slots: [SlotApp?] = Array(repeating: nil, count: slotCount),
        modules: [ModuleKind?] = ModuleKind.defaultLayout,
        activeSlot: SlotPosition? = nil,
        forceQuitEnabled: Bool = false,
        forceQuitTimeout: Double = 3,
        holdDuration: Double = 0.25,
        didShowAccessibilityIntro: Bool = false,
        mainCharacter: String = "",
        colorway: String? = nil,
        localAPIEnabled: Bool = false,
        projects: [String: ProjectStyle] = [:],
        colourBy: ColourBy = .performance,
        colourScale: [PerformanceLevel: String] = PerformanceLevel.defaultScale,
        didOnboard: Bool = false,
        islandDisplay: IslandDisplay = .automatic,
        disabledModules: [ModuleKind] = ToolSwitches.offModules,
        disabledFeatures: [ToolFeature] = ToolSwitches.offFeatures,
        brain: TaraBrain = .auto,
        keepOpenUntilClick: Bool = false,
        earsMode: EarsMode = .attention,
        watchAutomatic: Bool = true,
        watchTimer: WatchTimer = .twoHours,
        disabledProviders: [String] = [],
        remindersInToday: Bool = false,
        moduleOrder: [ModuleKind] = []
    ) {
        self.slots = Self.normalized(slots)
        self.modules = Self.normalized(modules)
        self.activeSlot = activeSlot
        self.forceQuitEnabled = forceQuitEnabled
        self.forceQuitTimeout = forceQuitTimeout
        self.holdDuration = holdDuration
        self.didShowAccessibilityIntro = didShowAccessibilityIntro
        self.mainCharacter = mainCharacter
        self.colorway = colorway
        self.localAPIEnabled = localAPIEnabled
        self.projects = projects
        self.colourBy = colourBy
        self.colourScale = colourScale
        self.didOnboard = didOnboard
        self.islandDisplay = islandDisplay
        self.disabledModules = disabledModules
        self.disabledFeatures = disabledFeatures
        self.knownTools = ToolSwitches.known
        self.brain = brain
        self.keepOpenUntilClick = keepOpenUntilClick
        self.earsMode = earsMode
        self.watchAutomatic = watchAutomatic
        self.watchTimer = watchTimer
        self.disabledProviders = disabledProviders
        self.remindersInToday = remindersInToday
        self.moduleOrder = moduleOrder
    }

    /// The app in a slot. Assigning an app replaces the slot's module.
    public subscript(slot: SlotPosition) -> SlotApp? {
        get { slots[slot.rawValue] }
        set {
            slots[slot.rawValue] = newValue
            if newValue != nil { modules[slot.rawValue] = nil }
        }
    }

    /// The module in a slot. Assigning a module replaces the slot's app.
    public subscript(module slot: SlotPosition) -> ModuleKind? {
        get { modules[slot.rawValue] }
        set {
            modules[slot.rawValue] = newValue
            if newValue != nil { slots[slot.rawValue] = nil }
        }
    }

    public func item(at slot: SlotPosition) -> SlotItem? {
        if let module = modules[slot.rawValue] { return .module(module) }
        return slots[slot.rawValue].map(SlotItem.app)
    }

    /// What the wheel offers in a slot: its item, unless that is a tab switched off in Tools.
    public func wheelItem(at slot: SlotPosition) -> SlotItem? {
        if case .module(let kind) = item(at: slot), !ToolSwitches.isOn(.module(kind), in: self) { return nil }
        return item(at: slot)
    }

    public var wheelSlots: Set<SlotPosition> {
        Set(SlotPosition.allCases.filter { wheelItem(at: $0) != nil })
    }

    public func position(of module: ModuleKind) -> SlotPosition? {
        SlotPosition.allCases.first { modules[$0.rawValue] == module }
    }

    public var assignedSlots: Set<SlotPosition> {
        Set(SlotPosition.allCases.filter { item(at: $0) != nil })
    }

    /// Bundle identifiers of the app slots, for `SwitchPlan`.
    public var appBundleIDs: [String?] {
        SlotPosition.allCases.map { modules[$0.rawValue] == nil ? slots[$0.rawValue]?.bundleID : nil }
    }

    static func normalized<T>(_ values: [T?]) -> [T?] {
        let padded = values + Array(repeating: nil, count: max(0, slotCount - values.count))
        return Array(padded.prefix(slotCount))
    }

    static func withoutModuleSlots(_ apps: [SlotApp?], modules: [ModuleKind?]) -> [SlotApp?] {
        let modules = normalized(modules)
        return normalized(apps).enumerated().map { index, app in modules[index] == nil ? app : nil }
    }

    // Tolerant decoding: missing keys fall back to defaults so older saved data keeps working.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SwitcherSettings()
        // Settings from the app switcher (variant A) have no modules: the default modules take
        // over and the old notch apps are dropped (an app slot can be set again in Settings).
        let storedModules = try c.decodeIfPresent([ModuleKind?].self, forKey: .modules)
        let modules = storedModules ?? ModuleKind.defaultLayout
        self.init(
            slots: storedModules == nil ? defaults.slots : Self.withoutModuleSlots(
                try c.decodeIfPresent([SlotApp?].self, forKey: .slots) ?? defaults.slots,
                modules: modules
            ),
            modules: modules,
            activeSlot: try c.decodeIfPresent(SlotPosition.self, forKey: .activeSlot),
            forceQuitEnabled: try c.decodeIfPresent(Bool.self, forKey: .forceQuitEnabled) ?? defaults.forceQuitEnabled,
            forceQuitTimeout: try c.decodeIfPresent(Double.self, forKey: .forceQuitTimeout) ?? defaults.forceQuitTimeout,
            holdDuration: try c.decodeIfPresent(Double.self, forKey: .holdDuration) ?? defaults.holdDuration,
            didShowAccessibilityIntro: try c.decodeIfPresent(Bool.self, forKey: .didShowAccessibilityIntro)
                ?? defaults.didShowAccessibilityIntro,
            mainCharacter: try c.decodeIfPresent(String.self, forKey: .mainCharacter) ?? defaults.mainCharacter,
            colorway: try c.decodeIfPresent(String.self, forKey: .colorway),
            localAPIEnabled: try c.decodeIfPresent(Bool.self, forKey: .localAPIEnabled) ?? defaults.localAPIEnabled,
            projects: (try? c.decodeIfPresent([String: ProjectStyle].self, forKey: .projects)) ?? [:],
            colourBy: (try? c.decodeIfPresent(ColourBy.self, forKey: .colourBy)) ?? .performance,
            colourScale: ((try? c.decodeIfPresent([PerformanceLevel: String].self, forKey: .colourScale)) ?? [:])
                .merging(PerformanceLevel.defaultScale) { saved, _ in saved },
            // Saved settings without the key come from before onboarding existed: don't show it.
            didOnboard: try c.decodeIfPresent(Bool.self, forKey: .didOnboard) ?? true,
            islandDisplay: (try? c.decodeIfPresent(IslandDisplay.self, forKey: .islandDisplay)) ?? .automatic,
            // Saved before the Tools gallery: every tool the user had stays on.
            disabledModules: (try? c.decodeIfPresent([ModuleKind].self, forKey: .disabledModules)) ?? [],
            disabledFeatures: (try? c.decodeIfPresent([ToolFeature].self, forKey: .disabledFeatures)) ?? [],
            brain: (try? c.decodeIfPresent(TaraBrain.self, forKey: .brain)) ?? .auto,
            keepOpenUntilClick: (try? c.decodeIfPresent(Bool.self, forKey: .keepOpenUntilClick)) ?? false,
            earsMode: (try? c.decodeIfPresent(EarsMode.self, forKey: .earsMode)) ?? .attention,
            watchAutomatic: (try? c.decodeIfPresent(Bool.self, forKey: .watchAutomatic)) ?? true,
            watchTimer: (try? c.decodeIfPresent(WatchTimer.self, forKey: .watchTimer)) ?? .twoHours,
            disabledProviders: (try? c.decodeIfPresent([String].self, forKey: .disabledProviders)) ?? [],
            remindersInToday: (try? c.decodeIfPresent(Bool.self, forKey: .remindersInToday)) ?? false,
            moduleOrder: (try? c.decodeIfPresent([ModuleKind].self, forKey: .moduleOrder)) ?? []
        )
        // Saved by an older version: tools added since start off. Without the stamp the settings
        // come from before it, and every tool of this version counts as known.
        if let known = try? c.decodeIfPresent([String].self, forKey: .knownTools) {
            ToolSwitches.switchOffNew(since: known, in: &self)
        }
    }
}

/// Persists `SwitcherSettings` as JSON in `UserDefaults`.
public final class SettingsStore {
    public static let defaultKey = "switcherSettings"

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = SettingsStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> SwitcherSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(SwitcherSettings.self, from: data) else {
            return SwitcherSettings()
        }
        return settings
    }

    public func save(_ settings: SwitcherSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
