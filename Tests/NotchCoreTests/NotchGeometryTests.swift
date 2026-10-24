import CoreGraphics
import Testing
@testable import NotchCore

@Suite struct NotchGeometryTests {
    // Values measured on a 14" MacBook Pro (Mac17,9) at default scaling.
    let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 982)

    @Test func notchFromAuxiliaryAreas() {
        let info = NotchGeometry.notch(
            screenFrame: builtIn,
            safeAreaTop: 32,
            auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 663, height: 32),
            auxiliaryTopRight: CGRect(x: 848, y: 950, width: 664, height: 32),
            menuBarHeight: 33
        )
        #expect(info.hasNotch)
        #expect(info.rect == CGRect(x: 663, y: 950, width: 185, height: 32))
    }

    @Test func screenLocalAuxiliaryAreasAreShiftedToGlobal() {
        // Built-in display placed to the right of a primary external display.
        let frame = CGRect(x: 2560, y: 0, width: 1512, height: 982)
        let info = NotchGeometry.notch(
            screenFrame: frame,
            safeAreaTop: 32,
            auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 663, height: 32),
            auxiliaryTopRight: CGRect(x: 848, y: 950, width: 664, height: 32),
            menuBarHeight: 33
        )
        #expect(info.hasNotch)
        #expect(info.rect == CGRect(x: 2560 + 663, y: 950, width: 185, height: 32))
    }

    @Test func fallbackWithoutNotch() {
        let external = CGRect(x: -2560, y: 0, width: 2560, height: 1440)
        let info = NotchGeometry.notch(
            screenFrame: external,
            safeAreaTop: 0,
            auxiliaryTopLeft: nil,
            auxiliaryTopRight: nil,
            menuBarHeight: 25
        )
        #expect(!info.hasNotch)
        #expect(info.rect == CGRect(x: -1280 - 100, y: 1415, width: 200, height: 25))
    }

    @Test func fallbackWithHiddenMenuBarUsesDefaultHeight() {
        let info = NotchGeometry.notch(
            screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            safeAreaTop: 0,
            auxiliaryTopLeft: nil,
            auxiliaryTopRight: nil,
            menuBarHeight: 0
        )
        #expect(info.rect.height == NotchGeometry.fallbackHeight)
        #expect(info.rect.maxY == 1080)
    }

    @Test func safeAreaWithoutAuxiliaryAreasFallsBack() {
        let info = NotchGeometry.notch(
            screenFrame: builtIn,
            safeAreaTop: 32,
            auxiliaryTopLeft: nil,
            auxiliaryTopRight: nil,
            menuBarHeight: 33
        )
        #expect(!info.hasNotch)
        #expect(info.rect.midX == builtIn.midX)
    }

    @Test func hotZoneIncludesTopEdgeAndTolerance() {
        let notch = CGRect(x: 663, y: 950, width: 185, height: 32)
        let zone = NotchGeometry.hotZone(for: notch)
        #expect(zone.contains(CGPoint(x: 755, y: 982)))      // topmost pixel row
        #expect(zone.contains(CGPoint(x: 660, y: 960)))      // just left of the notch
        #expect(!zone.contains(CGPoint(x: 755, y: 949)))     // below the notch
        #expect(!zone.contains(CGPoint(x: 600, y: 970)))     // menu bar, far left
    }
}
