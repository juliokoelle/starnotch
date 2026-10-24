import CoreGraphics

/// Where the notch (or, on screens without one, the hot zone at the top center) sits.
public struct NotchInfo: Equatable, Sendable {
    /// The notch rect in global AppKit coordinates (origin bottom-left of the primary screen).
    public var rect: CGRect
    /// `false` when the screen has no camera housing and `rect` is the fallback hot zone.
    public var hasNotch: Bool

    public init(rect: CGRect, hasNotch: Bool) {
        self.rect = rect
        self.hasNotch = hasNotch
    }
}

public enum NotchGeometry {
    /// Width of the press-and-hold zone on screens without a notch.
    public static let fallbackWidth: CGFloat = 200
    /// Height used when the menu bar is hidden and no height can be derived.
    public static let fallbackHeight: CGFloat = 24
    /// Extra tolerance around the notch so presses on its very edge still count.
    public static let edgeTolerance: CGFloat = 4

    /// Computes the notch rect for one screen.
    ///
    /// - Parameters:
    ///   - screenFrame: `NSScreen.frame` (global coordinates).
    ///   - safeAreaTop: `NSScreen.safeAreaInsets.top`; non-zero only on screens with a notch.
    ///   - auxiliaryTopLeft: `NSScreen.auxiliaryTopLeftArea`, the usable area left of the notch.
    ///   - auxiliaryTopRight: `NSScreen.auxiliaryTopRightArea`, the usable area right of the notch.
    ///   - menuBarHeight: `screenFrame.maxY - visibleFrame.maxY`, used for the fallback zone.
    public static func notch(
        screenFrame: CGRect,
        safeAreaTop: CGFloat,
        auxiliaryTopLeft: CGRect?,
        auxiliaryTopRight: CGRect?,
        menuBarHeight: CGFloat
    ) -> NotchInfo {
        if safeAreaTop > 0, var left = auxiliaryTopLeft, var right = auxiliaryTopRight {
            // The auxiliary areas are documented in the screen's coordinate space. Accept both
            // screen-local and global rects: shift local ones by the screen origin.
            if !screenFrame.contains(CGPoint(x: left.midX, y: left.midY)) {
                left = left.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY)
                right = right.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY)
            }
            let width = right.minX - left.maxX
            if width > 0 {
                let rect = CGRect(
                    x: left.maxX,
                    y: screenFrame.maxY - safeAreaTop,
                    width: width,
                    height: safeAreaTop
                )
                return NotchInfo(rect: rect, hasNotch: true)
            }
        }

        let height = menuBarHeight > 0 ? menuBarHeight : fallbackHeight
        let width = min(fallbackWidth, screenFrame.width)
        let rect = CGRect(
            x: screenFrame.midX - width / 2,
            y: screenFrame.maxY - height,
            width: width,
            height: height
        )
        return NotchInfo(rect: rect, hasNotch: false)
    }

    /// The zone in which a press starts the hold gesture: the notch plus a small tolerance,
    /// extended upward so the topmost pixel row (y == maxY) is included.
    public static func hotZone(for notch: CGRect) -> CGRect {
        CGRect(
            x: notch.minX - edgeTolerance,
            y: notch.minY,
            width: notch.width + 2 * edgeTolerance,
            height: notch.height + 2
        )
    }
}
