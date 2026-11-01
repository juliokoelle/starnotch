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

/// Whether resting the pointer on the notch opens the panel, and after how long. A click opens
/// it in every case.
public enum HoverOpen: String, Codable, CaseIterable, Sendable {
    case click, half, one

    /// Seconds on the notch before it opens; nil: only a click opens it.
    public var seconds: Double? {
        switch self {
        case .click: nil
        case .half: 0.5
        case .one: 1
        }
    }

    public var title: String {
        switch self {
        case .click: "Click only"
        case .half: "0.5 s"
        case .one: "1 s"
        }
    }
}

/// Tara beside the closed notch: always, only when something is up, or never. One choice for
/// the user over two stored values (`taraAlways`, `earsMode`).
public enum TaraBeside: String, CaseIterable, Sendable {
    case always, activity, never

    public var title: String {
        switch self {
        case .always: "Always"
        case .activity: "When something's up"
        case .never: "Never"
        }
    }
}

/// How Tara's moving eyes look: her own lines, or round eyes with pupils (after a teammate's mascot sketch).
public enum EyeStyle: String, Codable, CaseIterable, Sendable {
    case lines, round

    public var title: String {
        switch self {
        case .lines: "Lines"
        case .round: "Round"
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
    /// Every display: the island follows the pointer like `pointer`, and the others show a copy of
    /// it at rest (the same ears and lines, no second prompt or sound).
    case all

    public var title: String {
        switch self {
        case .automatic: "Notch"
        case .main: "Main display"
        case .pointer: "With pointer"
        case .all: "All displays"
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
    /// How Tara's background work thinks (condensing screen context); nil: like `brain`. Lets the
    /// summaries run on another plan (Codex) than the questions.
    public var backgroundBrain: TaraBrain?
    /// The open panel stays until a click outside (or Esc), not when the pointer leaves.
    public var keepOpenUntilClick: Bool
    /// Figures beside the notch at rest.
    public var earsMode: EarsMode
    /// Beside the notch at rest only Tara, on one side (the quiet look); on: both ears with
    /// counts and the other sessions. Off for new and existing users (settings saved before the
    /// switch have no key and decode as off).
    public var detailedEars: Bool
    /// Tara sits beside the closed notch even when nothing is going on.
    public var taraAlways: Bool
    /// Resting the pointer on the notch opens the panel after this long (a click always opens it).
    public var hoverOpen: HoverOpen
    /// The panel opens on the tab it was closed on; off: always on the first tab.
    public var reopenLastTab: Bool
    /// How Tara's moving eyes look.
    public var eyeStyle: EyeStyle
    /// Watch mode turns on by itself for fullscreen apps and video.
    public var watchAutomatic: Bool
    /// How long a manually started Watch mode lasts.
    public var watchTimer: WatchTimer
    /// Agent tools switched off in Settings › Providers (`ClaudeCodeProvider.id`, `CodexProvider.id`).
    public var disabledProviders: [String]
    /// Apple Reminders due today show in Today.
    public var remindersInToday: Bool
    /// Shuffle, repeat and favorite beside the transport in Now Playing, where the player has them.
    public var musicModes: Bool
    /// Check camera beside Join: a mirrored preview of the camera before a call.
    public var cameraCheck: Bool
    /// Time to leave for today's events with a place: the leave time in the event's card and a
    /// line when it's time to go. On by default; the location is asked for on a click only.
    public var timeToLeave: Bool
    /// How Apple Maps works out the way there when Calendar has no travel time.
    public var travelMode: TravelMode
    /// Zip, Open with, Share and Copy to for a file on the shelf. On by default.
    public var shelfActions: Bool
    /// The shelf's files are still there after a restart (bookmarks, nothing copied). On by default.
    public var shelfKeeps: Bool
    /// The "+" in Today adds a reminder, the one in the calendar an event; Today deletes a reminder
    /// with a short undo. On by default; macOS asks for access on the first save.
    public var addInNotch: Bool
    /// Apple Notes in the Notepad (read through Notes' scripting, on this Mac). Off by default.
    public var appleNotes: Bool
    /// Note captures are also copied into this Apple Notes folder (`notesDefault` for Notes' own
    /// default); nil: they aren't.
    public var appleNotesCapture: AppleNotesFolder?
    /// Tab order, set by dragging a tab in the island (`ModuleOrder`); empty = the built-in order.
    public var moduleOrder: [ModuleKind]
    /// The Tools tab's own tabs (Clipboard, Timer, Shelf, Notepad) in the order dragged there, by
    /// name; empty = the built-in order.
    public var toolOrder: [String]
    /// The launcher's shortcuts and apps in the Tools tab, in the order picked in Settings.
    public var launcher: [LauncherItem]
    /// Tara's memory: paused, sources switched off, apps kept out (Settings › Tara's memory).
    public var privacy: MemoryPrivacy
    /// All tools shows the tools that are off too, dimmed with Turn on; off: only those that are on.
    public var allToolsShowsOff: Bool
    /// A slim volume bar in the notch when the output volume or mute changes (Apple's HUD shows
    /// too). Off by default.
    public var levelHUD: Bool
    /// While the camera or microphone is in use or a calendar meeting runs, no sounds and no lines
    /// but agents' approvals and questions. On by default.
    public var meetingQuiet: Bool
    /// The island's width and height as a share of the notch (`NotchGeometry.islandScales`).
    public var islandWidthScale: Double
    public var islandHeightScale: Double
    /// A thin light outline around the island, so the pill shows on a dark menu bar.
    public var islandOutline: Bool

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
        backgroundBrain: TaraBrain? = nil,
        keepOpenUntilClick: Bool = false,
        earsMode: EarsMode = .attention,
        detailedEars: Bool = false,
        taraAlways: Bool = false,
        hoverOpen: HoverOpen = .click,
        reopenLastTab: Bool = true,
        eyeStyle: EyeStyle = .lines,
        watchAutomatic: Bool = true,
        watchTimer: WatchTimer = .twoHours,
        disabledProviders: [String] = [],
        remindersInToday: Bool = false,
        musicModes: Bool = true,
        cameraCheck: Bool = true,
        timeToLeave: Bool = true,
        travelMode: TravelMode = .driving,
        shelfActions: Bool = true,
        shelfKeeps: Bool = true,
        addInNotch: Bool = true,
        appleNotes: Bool = false,
        appleNotesCapture: AppleNotesFolder? = nil,
        moduleOrder: [ModuleKind] = [],
        toolOrder: [String] = [],
        launcher: [LauncherItem] = [],
        privacy: MemoryPrivacy = MemoryPrivacy(),
        allToolsShowsOff: Bool = true,
        levelHUD: Bool = false,
        meetingQuiet: Bool = true,
        islandWidthScale: Double = 1,
        islandHeightScale: Double = 1,
        islandOutline: Bool = false
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
        self.backgroundBrain = backgroundBrain
        self.keepOpenUntilClick = keepOpenUntilClick
        self.earsMode = earsMode
        self.detailedEars = detailedEars
        self.taraAlways = taraAlways
        self.hoverOpen = hoverOpen
        self.reopenLastTab = reopenLastTab
        self.eyeStyle = eyeStyle
        self.watchAutomatic = watchAutomatic
        self.watchTimer = watchTimer
        self.disabledProviders = disabledProviders
        self.remindersInToday = remindersInToday
        self.musicModes = musicModes
        self.cameraCheck = cameraCheck
        self.timeToLeave = timeToLeave
        self.travelMode = travelMode
        self.shelfActions = shelfActions
        self.shelfKeeps = shelfKeeps
        self.addInNotch = addInNotch
        self.appleNotes = appleNotes
        self.appleNotesCapture = appleNotesCapture
        self.moduleOrder = moduleOrder
        self.toolOrder = toolOrder
        self.launcher = launcher
        self.privacy = privacy
        self.allToolsShowsOff = allToolsShowsOff
        self.levelHUD = levelHUD
        self.meetingQuiet = meetingQuiet
        self.islandWidthScale = islandWidthScale
        self.islandHeightScale = islandHeightScale
        self.islandOutline = islandOutline
    }

    /// Tara beside the closed notch, as the user picks it. Always also shows activity (agents at
    /// work, music); Never hides the figures at rest altogether.
    public var taraBeside: TaraBeside {
        get { earsMode == .never ? .never : taraAlways ? .always : .activity }
        set {
            switch newValue {
            case .always: taraAlways = true; earsMode = .always
            case .activity: taraAlways = false; earsMode = .attention
            case .never: taraAlways = false; earsMode = .never
            }
        }
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
            backgroundBrain: try? c.decodeIfPresent(TaraBrain.self, forKey: .backgroundBrain),
            keepOpenUntilClick: (try? c.decodeIfPresent(Bool.self, forKey: .keepOpenUntilClick)) ?? false,
            earsMode: (try? c.decodeIfPresent(EarsMode.self, forKey: .earsMode)) ?? .attention,
            detailedEars: (try? c.decodeIfPresent(Bool.self, forKey: .detailedEars)) ?? false,
            taraAlways: (try? c.decodeIfPresent(Bool.self, forKey: .taraAlways)) ?? false,
            hoverOpen: (try? c.decodeIfPresent(HoverOpen.self, forKey: .hoverOpen)) ?? .click,
            reopenLastTab: (try? c.decodeIfPresent(Bool.self, forKey: .reopenLastTab)) ?? true,
            eyeStyle: (try? c.decodeIfPresent(EyeStyle.self, forKey: .eyeStyle)) ?? .lines,
            watchAutomatic: (try? c.decodeIfPresent(Bool.self, forKey: .watchAutomatic)) ?? true,
            watchTimer: (try? c.decodeIfPresent(WatchTimer.self, forKey: .watchTimer)) ?? .twoHours,
            disabledProviders: (try? c.decodeIfPresent([String].self, forKey: .disabledProviders)) ?? [],
            remindersInToday: (try? c.decodeIfPresent(Bool.self, forKey: .remindersInToday)) ?? false,
            musicModes: (try? c.decodeIfPresent(Bool.self, forKey: .musicModes)) ?? true,
            cameraCheck: (try? c.decodeIfPresent(Bool.self, forKey: .cameraCheck)) ?? true,
            timeToLeave: (try? c.decodeIfPresent(Bool.self, forKey: .timeToLeave)) ?? true,
            travelMode: (try? c.decodeIfPresent(TravelMode.self, forKey: .travelMode)) ?? .driving,
            shelfActions: (try? c.decodeIfPresent(Bool.self, forKey: .shelfActions)) ?? true,
            shelfKeeps: (try? c.decodeIfPresent(Bool.self, forKey: .shelfKeeps)) ?? true,
            addInNotch: (try? c.decodeIfPresent(Bool.self, forKey: .addInNotch)) ?? true,
            appleNotes: (try? c.decodeIfPresent(Bool.self, forKey: .appleNotes)) ?? false,
            appleNotesCapture: try? c.decodeIfPresent(AppleNotesFolder.self, forKey: .appleNotesCapture),
            moduleOrder: (try? c.decodeIfPresent([ModuleKind].self, forKey: .moduleOrder)) ?? [],
            toolOrder: (try? c.decodeIfPresent([String].self, forKey: .toolOrder)) ?? [],
            launcher: (try? c.decodeIfPresent([LauncherItem].self, forKey: .launcher)) ?? [],
            privacy: (try? c.decodeIfPresent(MemoryPrivacy.self, forKey: .privacy)) ?? MemoryPrivacy(),
            allToolsShowsOff: (try? c.decodeIfPresent(Bool.self, forKey: .allToolsShowsOff)) ?? true,
            levelHUD: (try? c.decodeIfPresent(Bool.self, forKey: .levelHUD)) ?? false,
            meetingQuiet: (try? c.decodeIfPresent(Bool.self, forKey: .meetingQuiet)) ?? true,
            islandWidthScale: (try? c.decodeIfPresent(Double.self, forKey: .islandWidthScale)) ?? 1,
            islandHeightScale: (try? c.decodeIfPresent(Double.self, forKey: .islandHeightScale)) ?? 1,
            islandOutline: (try? c.decodeIfPresent(Bool.self, forKey: .islandOutline)) ?? false
        )
        // Saved by an older version: tools added since start off. Without the stamp the settings
        // come from before it, and every tool of this version counts as known.
        if let known = try? c.decodeIfPresent([String].self, forKey: .knownTools) {
            ToolSwitches.switchOffNew(since: known, in: &self)
        } else {
            ToolSwitches.switchOffNew(since: ToolSwitches.knownBeforeStamp, in: &self)
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
