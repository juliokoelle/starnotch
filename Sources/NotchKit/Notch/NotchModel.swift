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
    /// Round-4 design preview (`--preview`): new modules and visuals that aren't shipped yet.
    var previewFeatures = false
    /// The moon in the panel: Watch mode on or off.
    @ObservationIgnored var toggleWatch: (() -> Void)?
    /// The "+" in the panel opens quick capture (preview).
    @ObservationIgnored var requestCapture: (() -> Void)?
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
    /// The notch or the closed island is pressed (from `WheelController`): Tara squashes.
    var handlePressed = false
    /// Music, for the headphones on the main character in any ear while it plays (set by the app delegate).
    @ObservationIgnored weak var music: NowPlayingModule?
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
        let pool = interaction == .rest && earsMode != .always ? active.filter(\.needsAttention) : active
        // At rest the first tab is the one in focus: it shows whenever it has something, even
        // when another module calls louder.
        if interaction == .rest, !pool.isEmpty, let first = modules.first, first.ambientPriority > 0 { return first }
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
    var earModule: NotchModule { ambient ?? restEarsShown ?? current }

    /// The module whose line shows under the notch on hover: never the rest ears, which have none.
    var peekModule: NotchModule { ambient ?? current }

    enum Presentation: Equatable { case closed, compact, sneak, peek, expanded, capture }

    var presentation: Presentation {
        switch interaction {
        case .rest:
            sneak != nil ? .sneak
                : ambient != nil && (held != nil && !watching || Quiet.showsEars(ambientLevel, mode: earsMode, watching: watching)) ? .compact
                : restEarsShown != nil ? .compact : .closed
        case .peek: .peek
        case .expanded: .expanded
        case .capture: .capture
        }
    }

    /// Menu bar icons beside the notch, as extents from its centre (set by `NotchController`);
    /// empty without Accessibility permission or on a display without a notch.
    var menuBarItems: [ClosedRange<CGFloat>] = []

    /// The open panel's size class: the current tab's, large while an approval card shows.
    var panelSize: PanelSize { approvals?.current != nil ? .large : current.panelSize }

    var layout: NotchLayout {
        let panel = panelSize
        return NotchLayout(presentation: presentation, notch: notchSize, panel: panel,
                           bodyHeight: approvals?.current.map { $0.request.asksForAnswer ? 196 : 150 } ?? panel.height,
                           earWidth: earModule.compactEarWidth, menuBarRoom: Runtime.menuBarRoom,
                           menuBarItems: menuBarItems)
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
    /// What the island may take of the menu bar beside the notch, per side, flare included.
    /// Peek, sneak and compact never grow past it, so menu bar extras stay uncovered.
    var menuBarRoom: CGFloat = 30
    /// Menu bar icons beside the notch, relative to its centre: the open island ends between them.
    var menuBarItems: [ClosedRange<CGFloat>] = []

    var topRadius: CGFloat {
        switch presentation {
        case .closed, .compact: 6
        case .peek, .sneak: 9
        case .expanded, .capture: 14
        }
    }

    var bottomRadius: CGFloat {
        switch presentation {
        case .closed: 9
        case .compact: 11
        case .peek, .sneak: 17
        case .expanded: 30
        case .capture: 24
        }
    }

    /// Width without the flares.
    var innerWidth: CGFloat {
        switch presentation {
        case .closed: notch.width
        case .compact: notch.width + 2 * compactEarWidth
        case .peek: notch.width + 2 * besideNotch
        // A sneak is unasked for: like the ears it stays out of the icons beside the notch.
        case .sneak: notch.width + 2 * min(besideNotch, earRoom)
        // The straight sides are what runs through the icons; the flares only touch the top rows.
        case .expanded:
            MenuBarFit.width(preferred: panel.width, in: panel.widthRange, items: menuBarItems)
        case .capture:
            MenuBarFit.width(preferred: Self.captureWidth, in: Self.captureWidth - 48 ... Self.captureWidth + 24, items: menuBarItems)
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

    /// Compact without room for ears: the island shows the dip with its mark.
    var showsCue: Bool { presentation == .compact && compactEarWidth == 0 }

    var height: CGFloat {
        switch presentation {
        case .closed: notch.height
        case .compact: showsCue ? notch.height + Self.cueDip : notch.height
        case .peek: notch.height + 40
        case .sneak: notch.height + 36
        case .expanded: notch.height + Self.bodyTop + min(bodyHeight, panel.height) + Self.bodyBottom
        case .capture: notch.height + 8 + 44 + 9 + 24 + 14
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
