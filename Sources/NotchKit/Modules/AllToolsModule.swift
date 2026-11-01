import NotchCore
import Observation
import SwiftUI

/// The last tab: every tool and function as a tile, grouped by area, with its shortcut. A click
/// starts or opens it; a tool that is off shows dimmed with Turn on, which switches it on as its
/// row in Settings › Tools does (macOS asks only then, where the tool asks). ↑↓ pick a tile, then
/// the arrows walk the grid, ↵ opens, esc lets go of the tile.
@MainActor
@Observable
final class AllToolsModule: NotchModule {
    let kind = ModuleKind.allTools
    let symbol = ModuleSymbols.symbol(.allTools)
    /// Tiles to a row in the large panel; the arrow keys walk the same grid.
    static let columns = 3

    /// The settings the tiles stand on, read in the body: a switch flipped anywhere shows at once.
    @ObservationIgnored var settings: () -> SwitcherSettings = { SwitcherSettings() }
    /// Each tab on this Mac (`ModuleAvailability`), looked up again when the panel opens or the
    /// switches change, not on every keystroke.
    @ObservationIgnored var lookUp: (ModuleKind) -> TabAvailability = { _ in .ready }
    private var availability: [ModuleKind: TabAvailability] = [:]
    /// What this build or Mac doesn't have (the Dashboard, the Markdown inbox behind a hub).
    @ObservationIgnored var missing: () -> Set<AllTool> = { [] }
    /// A switch that is on right now (keep awake, Watch mode): the tile says so.
    @ObservationIgnored var isActive: (AllTool) -> Bool = { _ in false }
    /// Why a tab isn't available here, for the tooltip.
    @ObservationIgnored var whyMissing: (ModuleKind) -> String = { _ in "" }
    @ObservationIgnored var open: (AllTool) -> Void = { _ in }
    @ObservationIgnored var turnOn: (AllTool) -> Void = { _ in }
    /// Settings › Tools: unavailable tiles and the hint at the end.
    @ObservationIgnored var openSettings: () -> Void = {}
    /// The tile under the keyboard; nil until ↑ or ↓ (← → switch tabs meanwhile, as everywhere).
    var selected: AllTool?

    var sections: [AllToolsSection] {
        AllTools.sections(settings: settings(), missing: missing()) { [availability] in availability[$0] ?? .ready }
    }

    var tiles: [AllToolsTile] { sections.flatMap(\.tiles) }

    func availability(of kind: ModuleKind) -> TabAvailability { availability[kind] ?? .ready }

    func refresh() {
        var found: [ModuleKind: TabAvailability] = [:]
        for kind in ModuleKind.allCases { found[kind] = lookUp(kind) }
        if found != availability { availability = found }
    }

    /// A click or ↵: opens what is on, turns on what is off, and shows Settings for what this Mac
    /// lacks (its row there says what).
    func activate(_ tile: AllToolsTile) {
        Haptics.tick()
        switch tile.state {
        case .on: open(tile.tool)
        case .off: turnOn(tile.tool)
        case .unavailable: openSettings()
        }
    }

    // MARK: NotchModule

    func leadingEar(peek: Bool) -> AnyView { AnyView(EmptyView()) }
    func trailingEar(peek: Bool) -> AnyView { AnyView(EmptyView()) }

    func peekLine() -> AnyView {
        AnyView(HStack(spacing: 8) {
            Image(systemName: self.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            Text("All tools").font(Theme.font(13, .medium)).foregroundStyle(Theme.textBody)
            let all = self.tiles
            Text(String(format: Localization.string("%d of %d on"), all.filter { $0.state == .on }.count, all.count))
                .font(Theme.font(12).monospacedDigit()).foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 0)
        }
        .lineLimit(1))
    }

    func body() -> AnyView { AnyView(AllToolsBody(module: self)) }

    /// ↵: the picked tile, or the first one picked.
    func primaryAction() {
        let tiles = tiles
        if let tile = tiles.first(where: { $0.tool == selected }) {
            activate(tile)
        } else if let first = tiles.first {
            Haptics.tick()
            withAnimation(Theme.snappy) { selected = first.tool }
        }
    }

    func handleKey(_ press: KeyPress) -> Bool {
        let step: AllToolsGrid.Step
        switch press.key {
        case .upArrow: step = .up
        case .downArrow: step = .down
        case .leftArrow where selected != nil: step = .left
        case .rightArrow where selected != nil: step = .right
        default: return false
        }
        let sections = sections
        let tiles = sections.flatMap(\.tiles)
        let index = tiles.firstIndex { $0.tool == selected }
        guard let next = AllToolsGrid.move(index, step, counts: sections.map(\.tiles.count), columns: Self.columns) else { return true }
        if tiles[next].tool != selected {
            Haptics.tick()
            withAnimation(Theme.snappy) { selected = tiles[next].tool }
        }
        return true
    }

    /// Esc lets go of the tile first, then closes.
    func handleBack() -> Bool {
        guard selected != nil else { return false }
        withAnimation(Theme.snappy) { selected = nil }
        return true
    }

    func setExpanded(_ expanded: Bool) {
        if expanded { refresh() } else { selected = nil }
    }

    // MARK: Symbols

    static func symbol(_ tool: AllTool, active: Bool = false) -> String {
        switch tool {
        case .agents: ModuleSymbols.symbol(.agents)
        case .agentsInbox: "tray"
        case .palette: "command"
        case .quickCapture: "square.and.pencil"
        case .captureInbox: "tray.full"
        case .askTara: "bubble.left.and.text.bubble.right"
        case .dictation: ModuleSymbols.symbol(.dictation)
        case .notepad: "note.text"
        case .appleNotes: "doc.text"
        case .calendar: ModuleSymbols.symbol(.calendar)
        case .today: ModuleSymbols.symbol(.today)
        case .meeting: ModuleSymbols.symbol(.meeting)
        case .joinMeeting: "video"
        case .checkCamera: "web.camera"
        case .addEvent: "calendar.badge.plus"
        case .addReminder: "plus.circle"
        case .music: ModuleSymbols.symbol(.nowPlaying)
        case .prompter: "text.alignleft"
        case .clipboard: ToolsModule.Tab.clipboard.symbol
        case .timer: ToolsModule.Tab.timer.symbol
        case .shelf: ToolsModule.Tab.shelf.symbol
        case .files: ToolsModule.Tab.files.symbol
        case .launcher: ToolsModule.Tab.launcher.symbol
        case .downloads: "arrow.down.circle"
        case .system: ModuleSymbols.symbol(.system)
        case .keepAwake: active ? "cup.and.saucer.fill" : "cup.and.saucer"
        case .watchMode: active ? "moon.fill" : "moon"
        case .dashboard: "house"
        case .settings: "gearshape"
        }
    }
}

/// The grid in sections, scrolling where it is longer than the panel; the picked tile scrolls
/// into view.
private struct AllToolsBody: View {
    let module: AllToolsModule

    var body: some View {
        let sections = module.sections
        let settings = module.settings()
        let showsHint = !settings.allToolsShowsOff || sections.contains { $0.tiles.contains { $0.state != .on } }
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(sections, id: \.area) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            SectionLabel(title: Localization.string(section.area.title))
                                .padding(.horizontal, 4)
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: AllToolsModule.columns),
                                      spacing: 5) {
                                ForEach(section.tiles, id: \.tool) { tile in
                                    AllToolsTileView(module: module, tile: tile, selected: module.selected == tile.tool)
                                        .id(tile.tool)
                                }
                            }
                        }
                    }
                    if showsHint { hint(showsOff: settings.allToolsShowsOff).id(Self.hintID) }
                }
            }
            .scrollEdgeFade(bottom: 14)
            .onChange(of: module.selected) { _, tool in
                guard let tool else { return }
                // In the last area the hint under it comes along.
                let last = sections.last?.tiles.contains { $0.tool == tool } == true && showsHint
                withAnimation(Theme.snappy) {
                    if last { proxy.scrollTo(Self.hintID, anchor: .bottom) } else { proxy.scrollTo(tool) }
                }
            }
        }
    }

    private static let hintID = "hint"

    /// Where to hide the tools that are off, or show them again.
    private func hint(showsOff: Bool) -> some View {
        Button {
            Haptics.tick()
            module.openSettings()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "gearshape").font(.system(size: 10, weight: .semibold))
                Text(showsOff ? "Hide switched-off tools in Settings › Tools" : "Show switched-off tools in Settings › Tools")
                    .font(Theme.font(11.5))
            }
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
    }
}

/// One tool: icon, name and its shortcut; dimmed with Turn on while off; "On" in the accent for a
/// switch that is on (keep awake, Watch mode).
private struct AllToolsTileView: View {
    let module: AllToolsModule
    let tile: AllToolsTile
    let selected: Bool

    var body: some View {
        let tool = tile.tool
        let on = tile.state == .on
        let active = on && module.isActive(tool)
        HoverRow(cornerRadius: 9, restOpacity: selected ? 0.12 : 0.05, hoverOpacity: selected ? 0.14 : 0.1, help: help) {
            module.activate(tile)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: AllToolsModule.symbol(tool, active: active))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(active ? Theme.accent : Theme.textBody)
                    .frame(width: 22, height: 22)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .opacity(on ? 1 : 0.45)
                Text(LocalizedStringKey(tool.title))
                    .font(Theme.font(12, .medium))
                    .foregroundStyle(on ? Theme.textBody : Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Spacer(minLength: 2)
                trailing(active: active)
            }
            .padding(.horizontal, 7)
            .frame(height: 32)
        }
        .animation(Theme.snappy, value: tile.state)
        .animation(Theme.snappy, value: active)
        .accessibilityLabel(Text(LocalizedStringKey(tool.title)))
        .accessibilityValue(Text(LocalizedStringKey(stateWord(active: active))))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func stateWord(active: Bool) -> String {
        switch tile.state {
        case .on: active ? "On" : ""
        case .off: "Off"
        case .unavailable: "Not available"
        }
    }

    @ViewBuilder private func trailing(active: Bool) -> some View {
        switch tile.state {
        case .on:
            if active {
                Text("On").font(Theme.font(11, .semibold)).foregroundStyle(Theme.accent)
            } else if let shortcut = tile.tool.shortcut {
                Text(verbatim: shortcut).font(Theme.font(11, .medium)).foregroundStyle(Theme.textTertiary)
            }
        case .off:
            ViewThatFits(in: .horizontal) {
                pill(Text("Turn on"))
                // A long name (German) keeps its room: the switch's symbol alone, Turn on in the tooltip.
                pill(Image(systemName: "power"))
            }
        case .unavailable:
            EmptyView()
        }
    }

    private func pill(_ label: some View) -> some View {
        label
            .font(Theme.font(11, .semibold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(Theme.accent.opacity(0.16), in: Capsule())
            .fixedSize()
    }

    /// What it does (its line in the Tools gallery), after Turn on while it is off, or why it isn't
    /// here; else its name and shortcut.
    private var help: String {
        let tool = tile.tool
        if tile.state == .unavailable, let tab = tool.tabs.first(where: { module.availability(of: $0) == .missing }) {
            return Localization.string(module.whyMissing(tab))
        }
        let title = Localization.string(tool.title)
        let line = tool.item.map { Localization.string(ToolInfo.line($0)) } ?? tool.shortcut.map { "\(title) (\($0))" } ?? title
        return tile.state == .off ? "\(Localization.string("Turn on")) · \(line)" : line
    }
}
