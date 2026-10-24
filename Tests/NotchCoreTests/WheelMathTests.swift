import CoreGraphics
import Testing
@testable import NotchCore

@Suite struct WheelMathTests {
    @Test(arguments: [
        (CGFloat(0), CGFloat(80), SlotPosition.top),
        (80, 0, .right),
        (0, -80, .bottom),
        (-80, 0, .left),
        (60, 50, .right),     // 40 degrees: still the right sector
        (50, 60, .top),       // 50 degrees: top sector
        (-70, -69, .left),
        (-69, -70, .bottom),
        (50, 50, .top),       // exact diagonal goes to the vertical slot
    ])
    func sectors(dx: CGFloat, dy: CGFloat, expected: SlotPosition) {
        #expect(WheelMath.slot(dx: dx, dy: dy, deadZone: 40) == expected)
    }

    @Test func deadZoneCancels() {
        #expect(WheelMath.slot(dx: 10, dy: 10, deadZone: 40) == nil)
        #expect(WheelMath.slot(dx: 0, dy: 0, deadZone: 40) == nil)
        #expect(WheelMath.slot(dx: 40, dy: 0, deadZone: 40) == .right)
    }

    @Test func maxDistanceLimitsClickMode() {
        #expect(WheelMath.slot(dx: 0, dy: 200, deadZone: 40, maxDistance: 150) == nil)
        #expect(WheelMath.slot(dx: 0, dy: 140, deadZone: 40, maxDistance: 150) == .top)
    }

    @Test func emptySlotsAreNotSelectable() {
        let assigned: Set<SlotPosition> = [.top, .left]
        #expect(WheelMath.selectableSlot(dx: 0, dy: 90, deadZone: 40, assigned: assigned) == .top)
        #expect(WheelMath.selectableSlot(dx: 90, dy: 0, deadZone: 40, assigned: assigned) == nil)
    }
}
