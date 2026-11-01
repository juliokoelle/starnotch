/// The All tools tab: every tool and function of the app as a tile, grouped by area, each with its
/// shortcut, in one fixed order. A tool that is off stays in the grid, dimmed, with Turn on (unless
/// the user hides those, `SwitcherSettings.allToolsShowsOff`); one that needs what this Mac
/// doesn't have shows as unavailable.
public enum AllTool: String, CaseIterable, Sendable {
    case agents, agentsInbox, palette
    case quickCapture, captureInbox, askTara, dictation, notepad, appleNotes
    case calendar, today, meeting, joinMeeting, checkCamera, addEvent, addReminder
    case music, prompter
    case clipboard, timer, shelf, files, launcher, downloads
    case system, keepAwake, watchMode, dashboard, settings

    public var area: AllToolsArea {
        switch self {
        case .agents, .agentsInbox, .palette: .agents
        case .quickCapture, .captureInbox, .askTara, .dictation, .notepad, .appleNotes: .capture
        case .calendar, .today, .meeting, .joinMeeting, .checkCamera, .addEvent, .addReminder: .meetings
        case .music, .prompter: .media
        case .clipboard, .timer, .shelf, .files, .launcher, .downloads: .files
        case .system, .keepAwake, .watchMode, .dashboard, .settings: .system
        }
    }

    public var title: String {
        switch self {
        case .agents: "Agents"
        case .agentsInbox: "Agents inbox"
        case .palette: "Command palette"
        case .quickCapture: "Quick capture"
        case .captureInbox: "Capture inbox"
        case .askTara: "Ask Tara"
        case .dictation: "Dictation"
        case .notepad: "Notepad"
        case .appleNotes: "Apple Notes"
        case .calendar: "Calendar"
        case .today: "Today"
        case .meeting: "Meeting agent"
        case .joinMeeting: "Join next meeting"
        case .checkCamera: "Check camera"
        case .addEvent: "New event"
        case .addReminder: "New reminder"
        case .music: "Music"
        case .prompter: "Teleprompter"
        case .clipboard: "Clipboard"
        case .timer: "Timer"
        case .shelf: "Shelf"
        case .files: "Files"
        case .launcher: "Launcher"
        case .downloads: "Downloads"
        case .system: "System"
        case .keepAwake: "Keep awake"
        case .watchMode: "Watch mode"
        case .dashboard: "Dashboard"
        case .settings: "Settings"
        }
    }

    /// The global shortcut that does the same, if there is one.
    public var shortcut: String? {
        switch self {
        case .agentsInbox: "⌃⌥A"
        case .palette: "⌃⌥K"
        case .quickCapture: "⌃⌥N"
        case .captureInbox: "⌃⌥I"
        case .askTara: "⌃⌥T"
        case .joinMeeting: "⌃⌥J"
        case .clipboard: "⌃⌥V"
        case .watchMode: "⌃⌥W"
        default: nil
        }
    }

    /// The Tools gallery's row this tile is, if it is one: its switch is the tile's.
    public var item: ToolItem? {
        switch self {
        case .agents: .module(.agents)
        case .quickCapture: .feature(.quickCapture)
        case .askTara: .feature(.askTara)
        case .dictation: .module(.dictation)
        case .notepad: .feature(.notes)
        case .calendar: .module(.calendar)
        case .today: .module(.today)
        case .meeting: .module(.meeting)
        case .music: .module(.nowPlaying)
        case .prompter: .feature(.prompter)
        case .clipboard: .feature(.clipboard)
        case .timer: .feature(.timers)
        case .shelf: .feature(.shelf)
        case .files: .feature(.files)
        case .launcher: .feature(.launcher)
        case .downloads: .feature(.downloads)
        case .system: .module(.system)
        case .keepAwake: .feature(.keepAwake)
        default: nil
        }
    }

    /// What has to be on for it to work. Empty: always there (the palette, Join, Watch mode,
    /// Settings, the Dashboard).
    public var needs: [AllToolsSwitch] {
        switch self {
        case .agentsInbox: [.tool(.module(.agents))]
        case .captureInbox: [.tool(.feature(.quickCapture))]
        case .appleNotes: [.tool(.feature(.notes)), .appleNotes]
        case .checkCamera: [.tool(.module(.calendar)), .cameraCheck]
        // The calendar's "+" and the one in its Today card.
        case .addEvent, .addReminder: [.tool(.module(.calendar)), .addInNotch]
        default: item.map { [.tool($0)] } ?? []
        }
    }

    /// The tabs it lives in (a small tool's tab included), whose availability on this Mac it shares.
    public var tabs: [ModuleKind] {
        needs.compactMap { need in
            guard case .tool(let item) = need else { return nil }
            switch item {
            case .module(let kind): return kind
            case .feature(let feature): return feature.module
            }
        }
    }
}

public enum AllToolsArea: String, CaseIterable, Sendable {
    case agents, capture, meetings, media, files, system

    public var title: String {
        switch self {
        case .agents: "Agents"
        case .capture: "Capture and Tara"
        case .meetings: "Meetings and calendar"
        case .media: "Media"
        case .files: "Files and tools"
        case .system: "System"
        }
    }
}

/// A switch a tile needs: a row of the Tools gallery, or one of the switches of their own in Settings.
public enum AllToolsSwitch: Hashable, Sendable {
    case tool(ToolItem)
    /// Settings › Apple Notes (macOS asks whether the app may control Notes on its click).
    case appleNotes
    /// Settings › Tools › Check camera before a meeting.
    case cameraCheck
    /// Settings › Tools › Add reminders and events in the notch.
    case addInNotch
}

public enum AllToolsState: Sendable {
    case on, off
    /// Needs what isn't on this Mac (Claude Code, Wispr Flow, calendar access …).
    case unavailable
}

/// A tab on this Mac: there, there once the switch's click asks macOS (Today turning on Apple
/// Reminders), or missing what it needs.
public enum TabAvailability: Sendable {
    case ready, asks, missing
}

public struct AllToolsTile: Equatable, Sendable {
    public let tool: AllTool
    public let state: AllToolsState
}

public struct AllToolsSection: Equatable, Sendable {
    public let area: AllToolsArea
    public let tiles: [AllToolsTile]
}

public enum AllTools {
    /// The grid: the areas in their order, each tool once in its area's order. `missing` leaves out
    /// what this build or Mac doesn't have (the Dashboard, the Markdown inbox behind a hub).
    public static func sections(settings: SwitcherSettings, missing: Set<AllTool> = [],
                                available: (ModuleKind) -> TabAvailability) -> [AllToolsSection] {
        AllToolsArea.allCases.compactMap { area in
            let tiles = AllTool.allCases
                .filter { $0.area == area && !missing.contains($0) }
                .map { AllToolsTile(tool: $0, state: state(of: $0, in: settings, available: available)) }
                .filter { settings.allToolsShowsOff || $0.state == .on }
            return tiles.isEmpty ? nil : AllToolsSection(area: area, tiles: tiles)
        }
    }

    /// On only with every switch it needs on and its tabs there; a tab missing what it needs makes it
    /// unavailable, whatever the switches say.
    public static func state(of tool: AllTool, in settings: SwitcherSettings,
                             available: (ModuleKind) -> TabAvailability) -> AllToolsState {
        let tabs = tool.tabs.map(available)
        if tabs.contains(.missing) { return .unavailable }
        return tool.needs.allSatisfy { isOn($0, in: settings) } && tabs.allSatisfy { $0 == .ready } ? .on : .off
    }

    public static func isOn(_ need: AllToolsSwitch, in settings: SwitcherSettings) -> Bool {
        switch need {
        case .tool(let item): ToolSwitches.isOn(item, in: settings)
        case .appleNotes: settings.appleNotes
        case .cameraCheck: settings.cameraCheck
        case .addInNotch: settings.addInNotch
        }
    }

    /// Turn on's switch, once macOS has said yes where it asks (Apple Notes, Today's Reminders).
    public static func set(_ need: AllToolsSwitch, on: Bool, in settings: inout SwitcherSettings) {
        switch need {
        case .tool(let item): ToolSwitches.set(item, on: on, in: &settings)
        case .appleNotes: settings.appleNotes = on
        case .cameraCheck: settings.cameraCheck = on
        case .addInNotch: settings.addInNotch = on
        }
    }
}

/// Arrow keys over the All tools grid: positions run through the sections' tiles in order, each
/// section starting a new row of `columns`.
public enum AllToolsGrid {
    public enum Step: Sendable { case up, down, left, right }

    /// The position after `step`: left and right walk the order, up and down keep the column (or
    /// the row's last tile) across rows and sections. Nothing picked yet: the first tile. At an
    /// edge it stays; nil when there are no tiles.
    public static func move(_ index: Int?, _ step: Step, counts: [Int], columns: Int) -> Int? {
        let total = counts.reduce(0, +)
        guard total > 0, columns > 0 else { return nil }
        guard let index, (0..<total).contains(index) else { return 0 }
        var rows: [Range<Int>] = []
        var start = 0
        for count in counts where count > 0 {
            for row in stride(from: start, to: start + count, by: columns) { rows.append(row ..< min(row + columns, start + count)) }
            start += count
        }
        guard let row = rows.firstIndex(where: { $0.contains(index) }) else { return index }
        let column = index - rows[row].lowerBound
        func land(_ target: Int) -> Int { min(rows[target].lowerBound + column, rows[target].upperBound - 1) }
        switch step {
        case .left: return max(index - 1, 0)
        case .right: return min(index + 1, total - 1)
        case .up: return row > 0 ? land(row - 1) : index
        case .down: return row < rows.count - 1 ? land(row + 1) : index
        }
    }
}
