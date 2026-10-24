import CoreGraphics

/// The four slots of the wheel, clockwise from the top.
public enum SlotPosition: Int, CaseIterable, Codable, Sendable {
    case top = 0, right, bottom, left

    public var label: String {
        switch self {
        case .top: "Top"
        case .right: "Right"
        case .bottom: "Bottom"
        case .left: "Left"
        }
    }

    /// Unit direction in a y-up coordinate system.
    public var direction: CGVector {
        switch self {
        case .top: CGVector(dx: 0, dy: 1)
        case .right: CGVector(dx: 1, dy: 0)
        case .bottom: CGVector(dx: 0, dy: -1)
        case .left: CGVector(dx: -1, dy: 0)
        }
    }
}

public enum WheelMath {
    /// Maps a pointer offset from the wheel center to a slot.
    ///
    /// Each slot owns a 90 degree sector centered on its direction. Offsets inside the
    /// dead zone (the center hub) map to `nil`, which means "cancel".
    ///
    /// - Parameters:
    ///   - dx: Horizontal offset, positive to the right.
    ///   - dy: Vertical offset, positive upward (AppKit convention).
    ///   - deadZone: Radius of the center hub.
    ///   - maxDistance: Optional outer limit; offsets beyond it map to `nil`.
    public static func slot(
        dx: CGFloat,
        dy: CGFloat,
        deadZone: CGFloat,
        maxDistance: CGFloat? = nil
    ) -> SlotPosition? {
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance >= deadZone else { return nil }
        if let maxDistance, distance > maxDistance { return nil }
        // Ties on the diagonals go to the vertical slots.
        if abs(dy) >= abs(dx) {
            return dy > 0 ? .top : .bottom
        }
        return dx > 0 ? .right : .left
    }

    /// Like `slot(dx:dy:deadZone:maxDistance:)` but only returns slots that are assigned.
    public static func selectableSlot(
        dx: CGFloat,
        dy: CGFloat,
        deadZone: CGFloat,
        maxDistance: CGFloat? = nil,
        assigned: Set<SlotPosition>
    ) -> SlotPosition? {
        guard let slot = slot(dx: dx, dy: dy, deadZone: deadZone, maxDistance: maxDistance),
              assigned.contains(slot) else { return nil }
        return slot
    }
}
