import AppKit
import NotchCore
import Observation

/// Everything the wheel view renders. Owned and mutated by `WheelController`.
@MainActor
@Observable
final class WheelModel {
    enum Mode { case hold, click }

    struct Slot {
        var name: String
        /// App icon for app slots.
        var icon: NSImage?
        /// SF Symbol for module slots.
        var symbol: String?
    }

    var isPresented = false
    var mode: Mode = .hold
    var slots: [SlotPosition: Slot] = [:]
    var activeSlot: SlotPosition?
    var highlighted: SlotPosition?
    /// Rotation of the highlight sector in degrees, accumulated so it always takes the short way.
    var highlightAngle: Double = 0
    /// Wheel center in the panel's view coordinates (origin top-left).
    var center: CGPoint = .zero

    func setHighlight(_ slot: SlotPosition?) {
        if let slot {
            let target = Double(slot.rawValue) * 90
            var delta = (target - highlightAngle).truncatingRemainder(dividingBy: 360)
            if delta > 180 { delta -= 360 }
            if delta < -180 { delta += 360 }
            // When the highlight was hidden, jump instead of sweeping across the wheel.
            highlightAngle = highlighted == nil ? target : highlightAngle + delta
        }
        highlighted = slot
    }
}

enum WheelMetrics {
    static let diameter: CGFloat = 300
    static var radius: CGFloat { diameter / 2 }
    static let hubRadius: CGFloat = 46
    static var slotRadius: CGFloat { (hubRadius + radius) / 2 + 2 }
    static let iconSize: CGFloat = 46
    /// Space between the notch and the top of the wheel.
    static let gapBelowNotch: CGFloat = 10
}
