import AppKit
import NotchCore

extension NSScreen {
    /// The notch of this screen, or the fallback hot zone at its top center.
    var notch: NotchInfo {
        NotchGeometry.notch(
            screenFrame: frame,
            safeAreaTop: safeAreaInsets.top,
            auxiliaryTopLeft: auxiliaryTopLeftArea,
            auxiliaryTopRight: auxiliaryTopRightArea,
            menuBarHeight: frame.maxY - visibleFrame.maxY
        )
    }

    /// The screen whose notch hot zone contains a point in global AppKit coordinates.
    static func withHotZone(containing point: NSPoint) -> NSScreen? {
        screens.first { NotchGeometry.hotZone(for: $0.notch.rect).contains(point) }
    }

    /// Prefers the built-in screen with a notch, then the screen under the pointer.
    static var preferredForWheel: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return screens.first { $0.notch.hasNotch && $0.frame.contains(mouse) }
            ?? screens.first { $0.frame.contains(mouse) }
            ?? main
    }
}
