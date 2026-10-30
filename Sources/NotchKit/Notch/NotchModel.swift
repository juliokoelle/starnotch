import AppKit
import NotchCore
import Observation
import SwiftUI

/// The island's state. Owned and mutated by `NotchController`, rendered by `NotchRootView`.
@MainActor
@Observable
final class NotchModel {
    enum Interaction: Equatable {
        /// Nothing hovered: the island is the notch, or the compact ears when a module has something to show.
        case rest
        case peek
        case expanded
        /// Quick capture field (design preview).
        case capture
        /// Command palette (⌃⌥K, ⌘K while open).
        case palette
        /// Agents inbox (⌃⌥A): what needs the user, one at a time.
        case inbox
    }

    var interaction = Interaction.rest
    var module = ModuleKind.agents
    /// +1 when the last tab change went right, -1 when left; content slides that way.
    var direction: CGFloat = 1
    /// Size of the hardware notch (or the fallback zone).
    var notchSize = CGSize(width: 185, height: 32)
    var hasNotch = true
    /// The panel has keyboard focus (opened with the shortcut).
    var keyboardFocus = false
    /// A sneak peek on the closed island (driven by `NotchController.sneak`).
    var sneak: Sneak?
    /// Quick capture while open.
    var capture: QuickCapture?
    /// The command palette while open.
    var palette: CommandPalette?
    /// Everything agents and loops need from the user (also counted in the Agents ear).
    var inbox: AgentsInbox?
    /// Round-4 design preview (`--preview`): new modules and visuals that aren't shipped yet.
    var previewFeatures = false
    /// The moon in the panel: Watch mode on or off.
    @ObservationIgnored var toggleWatch: (() -> Void)?
    /// The "+" in the panel opens quick capture (preview).
    @ObservationIgnored var requestCapture: (() -> Void)?
    /// Tara's memory is paused: a badge beside the tabs says so, a click resumes it.
    var memoryPaused = false
    @ObservationIgnored var resumeMemory: (() -> Void)?
    /// Previews (`+reading`, `+off`): whether screen context reads, without reading anything.
    var previewScreenReading: Bool?

    /// Tara in the island rests (dimmed, asleep where she has no other news) while her memory is
    /// paused, or while screen context is switched on but not reading (paused, locked). Switched off
    /// (the default) she stays awake, so most people never see her asleep without a reason.
    var taraResting: Bool {
        if memoryPaused { return true }
        if let preview = previewScreenReading { return !preview }
        return false
    }
    @ObservationIgnored var pauseMemory: ((MemoryPause) -> Void)?
    /// A tab was dragged to a new place: the visible modules in their new order, to save.
    @ObservationIgnored var onReorder: (([ModuleKind]) -> Void)?

    /// The modules shown, in tab order (hidden ones are left out; see `ModuleAvailability`).
    var modules: [NotchModule]
    /// Avatars for sneak lines (set by the app delegate).
    var cast: AvatarCast?
    /// Permission prompts from Claude Code; while one waits, the panel shows it.
    var approvals: ApprovalCenter?

    init(modules: [NotchModule]) {
        self.modules = modules
    }

    func module(_ kind: ModuleKind) -> NotchModule? { modules.first { $0.kind == kind } }

    var current: NotchModule { module(module) ?? modules[0] }

    /// The module sitting beside the notch at rest, if any.
    /// Figures beside the notch at rest (a setting) and Watch mode (everything quiet).
    var earsMode = EarsMode.attention
    /// Both ears with counts and the other sessions (a setting); off: the quiet look, only Tara
    /// on the left of the notch.
    var detailedEars = false
    /// Tara beside the closed notch even when nothing is going on (a setting).
    var taraAlways = false
    /// The notch or the closed island is pressed (from `WheelController`): Tara squashes.
    var handlePressed = false
    var watching = false

    private var active: [NotchModule] { modules.filter { $0.ambientPriority > 0 } }

    /// What the modules have to show at rest.
    var ambientLevel: Quiet.Ambient {
        if active.contains(where: \.needsAttention) { return .attention }
        return active.isEmpty ? .none : .activity
    }

    /// The module whose ears show; at rest by default only one that needs the user.
    var ambient: NotchModule? {
        if let held { return held }
        var pool = interaction == .rest && earsMode != .always ? active.filter(\.needsAttention) : active
        // The quiet look, at rest and on hover: only what is actively relevant (`quietRelevant`),
        // never the system's stats for a load that is merely high. Tara takes the rest.
        if !detailedEars { pool = pool.filter(\.quietRelevant) }
        // At rest (and in the quiet look also on hover) the first tab is the one in focus: it
        // shows whenever it has something, even when another module calls louder. In the quiet
        // look only when it is relevant itself.
        if interaction == .rest || !detailedEars, !pool.isEmpty, let first = modules.first, first.ambientPriority > 0,
           detailedEars || pool.contains(where: { $0 === first }) { return first }
        return pool.max { $0.ambientPriority < $1.ambientPriority }
    }

    /// From this priority on a module that needs the user beats one that holds the ears: a
    /// meeting about to start or recording, dictation listening.
    static let urgentPriority = 30

    /// A module that holds the ears (`holdsEars`), unless something urgent needs the user.
    private var held: NotchModule? {
        guard interaction == .rest || interaction == .peek, let held = modules.first(where: \.holdsEars) else { return nil }
        let urgent = active.contains { $0 !== held && $0.needsAttention && $0.ambientPriority >= Self.urgentPriority }
        return urgent ? nil : held
    }

    /// Ears at rest when no module has anything to show: the weather or the day's progress, when
    /// the user put them beside the notch (`DailyEars`). They stay on hover, so the ears don't jump
    /// to the tab's. Not while watching or with ears set to Never.
    @ObservationIgnored var restEars: () -> NotchModule? = { nil }

    private var restEarsShown: NotchModule? {
        guard interaction == .rest || interaction == .peek, ambient == nil, !watching, earsMode != .never else { return nil }
        return restEars()
    }

    /// The module whose ears show while not expanded.
    var earModule: NotchModule { ambient ?? restEarsShown ?? idle }

    /// The module whose line shows under the notch on hover: never the rest ears, which have none.
    var peekModule: NotchModule { ambient ?? idle }

    /// Ears and peek line when nothing else claims them: the open tab, or in the quiet look Tara
    /// (the agents module), so a hover never shows the stats of the tab that was open last.
    private var idle: NotchModule { detailedEars ? current : module(.agents) ?? current }

    enum Presentation: Equatable { case closed, compact, sneak, peek, expanded, capture, palette, inbox }

    var presentation: Presentation {
        switch interaction {
        case .rest:
            sneak != nil ? .sneak
                : ambient != nil && (held != nil && !watching || Quiet.showsEars(ambientLevel, mode: earsMode, watching: watching)) ? .compact
                : restEarsShown != nil || taraAlways && !watching && earsMode != .never ? .compact : .closed
        case .peek: .peek
        case .expanded: .expanded
        case .capture: .capture
        case .palette: .palette
        case .inbox: .inbox
        }
    }

    /// Menu bar icons beside the notch, as extents from its centre (set by `NotchController`);
    /// empty without Accessibility permission or on a display without a notch.
    var menuBarItems: [ClosedRange<CGFloat>] = []

    /// The open panel's size class: the current tab's, large while an approval card shows.
    var panelSize: PanelSize { approvals?.current != nil || interaction == .inbox ? .large : current.panelSize }

    var layout: NotchLayout {
        let panel = panelSize
        return NotchLayout(presentation: presentation, notch: notchSize, panel: panel,
                           bodyHeight: interaction == .inbox ? inbox?.bodyHeight ?? InboxView.emptyHeight
                               : approvals?.current.map { $0.request.asksForAnswer ? 196 : 150 } ?? panel.height,
                           earWidth: earModule.compactEarWidth, oneEar: !detailedEars, peekStyle: peekStyle,
                           menuBarRoom: Runtime.menuBarRoom, menuBarItems: menuBarItems)
    }

    /// The hover peek's shape: in the quiet look, while Tara is the one hovered, sized to her and
    /// her line (`NotchLayout.PeekStyle`) instead of a band across both ears.
    private var peekStyle: NotchLayout.PeekStyle {
        guard interaction == .peek, !detailedEars, !watching, let agents = peekModule as? AgentsModule else { return .line }
        return agents.inboxCount == 0 && earModule === agents ? .ear : .earLine
    }
}

/// Sizes of the island per presentation. The width includes the two concave flares at the top.
struct NotchLayout: Equatable {
    /// Tabs open in one of two panel sizes (`PanelSize`, picked per module): content tabs large,
    /// music, dictation and tools compact. A module fills its panel, and what is longer scrolls
    /// inside. Only an approval card asks for less. These are the large panel's numbers.
    static let expandedWidth: CGFloat = PanelSize.large.width
    /// The open panel narrows or widens within its size's range so its edges end between two menu
    /// bar icons instead of cutting one in half (`MenuBarFit`).
    static let minExpandedWidth: CGFloat = PanelSize.large.widthRange.lowerBound
    static let maxExpandedWidth: CGFloat = PanelSize.large.widthRange.upperBound
    /// Quick capture, fitted the same way.
    static let captureWidth: CGFloat = 520
    /// The command palette: a little wider than capture, for a title and its context per row.
    static let paletteWidth: CGFloat = 560
    /// The middle between the old Agents (about 180) and Calendar (about 386) panels.
    static let panelHeight: CGFloat = PanelSize.large.height
    /// An ear narrower than this shows nothing rather than a sliver of a figure.
    static let minEarWidth: CGFloat = 14
    /// Ears without room in the menu bar: the island dips this far below the notch instead, with
    /// a small mark, so something waiting still shows at rest.
    static let cueDip: CGFloat = 6
    /// Compact ears stay inside the gap between the hardware notch and the first menu extra
    /// (about 30 pt on a 14" MacBook Pro: measured 21.10.); with the 6 pt flare, 24 pt fits.
    static let earWidth: CGFloat = 24
    static let bodyTop: CGFloat = 8
    static let bodyBottom: CGFloat = 12
    static let sideInset: CGFloat = 12

    var presentation: NotchModel.Presentation
    var notch: CGSize
    /// The open panel's size class.
    var panel: PanelSize = .large
    /// The panel body: the size class's height, less for an approval card.
    var bodyHeight: CGFloat = NotchLayout.panelHeight
    /// Width of each ear at rest (the ear module may ask for more than the default).
    var earWidth: CGFloat = NotchLayout.earWidth
    /// The quiet look: at rest only the left ear, the right edge flush with the notch.
    var oneEar = false
    /// The hover peek's shape. `line`: a line under the notch across both ears. In the quiet look,
    /// while Tara is the one hovered, the peek keeps the one-eared shape of the rest: `ear` with
    /// nothing below the notch (she grows in her ear; a band holding only her read as a dead black
    /// bar), `earLine` with a band just tall enough for her and the line of what waits.
    enum PeekStyle: Equatable { case line, ear, earLine }
    var peekStyle = PeekStyle.line
    /// What the island may take of the menu bar beside the notch, per side, flare included.
    /// Peek, sneak and compact never grow past it, so menu bar extras stay uncovered.
    var menuBarRoom: CGFloat = 30
    /// Menu bar icons beside the notch, relative to its centre: the open island ends between them.
    var menuBarItems: [ClosedRange<CGFloat>] = []

    var topRadius: CGFloat {
        switch presentation {
        case .closed, .compact: 6
        // One-eared like the rest: the same flares, so the island's edges stay where they were.
        case .peek where peekStyle != .line: 6
        case .peek, .sneak: 9
        case .expanded, .capture, .palette, .inbox: 14
        }
    }

    var bottomRadius: CGFloat {
        switch presentation {
        case .closed: 9
        case .compact: 11
        case .peek where peek == .ear: 11
        case .peek, .sneak: 17
        case .expanded, .inbox: 30
        case .capture, .palette: 24
        }
    }

    /// Width without the flares.
    var innerWidth: CGFloat {
        switch presentation {
        case .closed: notch.width
        case .compact: restIsland.width
        case .peek: peek == .line ? notch.width + 2 * besideNotch : oneEarIsland.width
        // A sneak is unasked for: like the ears it stays out of the icons beside the notch.
        case .sneak: notch.width + 2 * min(besideNotch, earRoom)
        // The straight sides are what runs through the icons; the flares only touch the top rows.
        case .expanded, .inbox:
            MenuBarFit.width(preferred: panel.width, in: panel.widthRange, items: menuBarItems)
        case .capture:
            MenuBarFit.width(preferred: Self.captureWidth, in: Self.captureWidth - 48 ... Self.captureWidth + 24, items: menuBarItems)
        case .palette:
            MenuBarFit.width(preferred: Self.paletteWidth, in: Self.paletteWidth - 24 ... Self.paletteWidth + 24, items: menuBarItems)
        }
    }

    /// Room for content beside the notch: the menu bar room minus the curved corner.
    var besideNotch: CGFloat { max(0, menuBarRoom - topRadius) }

    /// Room beside the notch, per side, that covers no menu bar icon: the menu bar room, less
    /// where an icon sits closer to the notch (macOS puts a long status item right beside it when
    /// the right side is full), minus the curved corner.
    var earRoom: CGFloat {
        max(0, MenuBarFit.earRoom(halfNotch: notch.width / 2, limit: menuBarRoom, items: menuBarItems) - topRadius)
    }

    /// Each ear at rest: as wide as the module asks, within `earRoom`. Too little room hides the
    /// ears (the island shows `cueDip` instead); the peek line still has it all.
    var compactEarWidth: CGFloat {
        let width = min(earWidth, earRoom)
        return width < Self.minEarWidth ? 0 : width
    }

    private var restIsland: (width: CGFloat, offset: CGFloat) {
        Quiet.restIsland(notchWidth: notch.width, ear: compactEarWidth, oneSided: oneEar)
    }

    private var oneEarIsland: (width: CGFloat, offset: CGFloat) {
        Quiet.restIsland(notchWidth: notch.width, ear: compactEarWidth, oneSided: true)
    }

    /// The peek's shape as drawn: Tara can't grow in an ear there is no room for, so then she
    /// takes the band under the notch.
    var peek: PeekStyle { peekStyle == .ear && compactEarWidth == 0 ? .earLine : peekStyle }

    /// Below the notch in the one-eared peek: Tara whole and the line beside her.
    static let quietBand: CGFloat = 38

    /// How far the island's centre sits left (negative) of the notch's: only with one ear at rest
    /// and in the one-eared peek.
    var centerOffset: CGFloat {
        switch presentation {
        case .compact: restIsland.offset
        case .peek where peek != .line: oneEarIsland.offset
        default: 0
        }
    }

    /// Where Tara stands on the island at rest and in the peek, flares included: whole inside the
    /// left ear (also when hovered with nothing below the notch), or at the start of the line
    /// under it, clear of the bottom corners. One place per state, so she moves and grows between
    /// them as one figure.
    var taraBox: CGRect {
        if presentation == .peek && peek != .ear {
            return CGRect(x: topRadius + 12, y: notch.height + 1, width: 44, height: max(0, height - notch.height - 4))
        }
        let ear = compactEarWidth
        let side = max(0, presentation == .peek ? min(ear, notch.height - 8) : min(ear - 3, notch.height - 11))
        return CGRect(x: topRadius + (ear - side) / 2, y: (notch.height - side) / 2, width: side, height: side)
    }

    /// Compact without room for ears: the island shows the dip with its mark.
    var showsCue: Bool { presentation == .compact && compactEarWidth == 0 }

    var height: CGFloat {
        switch presentation {
        case .closed: notch.height
        case .compact: showsCue ? notch.height + Self.cueDip : notch.height
        case .peek:
            switch peek {
            case .line: notch.height + 40
            case .ear: notch.height
            case .earLine: notch.height + Self.quietBand
            }
        case .sneak: notch.height + 36
        case .expanded, .inbox: notch.height + Self.bodyTop + min(bodyHeight, panel.height) + Self.bodyBottom
        case .capture: notch.height + 8 + 44 + 9 + 24 + 14
        // The field and six rows; fewer results leave the room empty instead of resizing.
        case .palette: notch.height + 8 + PaletteView.fieldHeight + 6 + PaletteView.visibleRows * PaletteView.rowHeight + 10
        }
    }

    var size: CGSize { CGSize(width: innerWidth + 2 * topRadius, height: height) }

    /// Largest island, for the panel frame.
    static func maxSize(notch: CGSize) -> CGSize {
        CGSize(width: maxExpandedWidth + 2 * 14, height: notch.height + bodyTop + panelHeight + bodyBottom)
    }
}

/// The notch outline: concave flares where it meets the top edge, continuous-looking convex
/// corners at the bottom. Both radii animate, so the island morphs instead of cross-fading.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let t = min(topRadius, rect.width / 4)
        let b = min(bottomRadius, (rect.width - 2 * t) / 2, rect.height - t)
        // Control-point factor > 0.552 (circle) gives the softer, squircle-like corner.
        let k: CGFloat = 0.62
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // Top-left flare, curving inward and down.
        p.addCurve(
            to: CGPoint(x: rect.minX + t, y: rect.minY + t),
            control1: CGPoint(x: rect.minX + t * k, y: rect.minY),
            control2: CGPoint(x: rect.minX + t, y: rect.minY + t * (1 - k))
        )
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        // Bottom-left corner.
        p.addCurve(
            to: CGPoint(x: rect.minX + t + b, y: rect.maxY),
            control1: CGPoint(x: rect.minX + t, y: rect.maxY - b * (1 - k)),
            control2: CGPoint(x: rect.minX + t + b * (1 - k), y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        // Bottom-right corner.
        p.addCurve(
            to: CGPoint(x: rect.maxX - t, y: rect.maxY - b),
            control1: CGPoint(x: rect.maxX - t - b * (1 - k), y: rect.maxY),
            control2: CGPoint(x: rect.maxX - t, y: rect.maxY - b * (1 - k))
        )
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        // Top-right flare.
        p.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control1: CGPoint(x: rect.maxX - t, y: rect.minY + t * (1 - k)),
            control2: CGPoint(x: rect.maxX - t * k, y: rect.minY)
        )
        p.closeSubpath()
        return p
    }
}
