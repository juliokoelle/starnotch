import CoreGraphics
import Testing
@testable import NotchCore

@Suite struct MenuBarFitTests {
    let range: ClosedRange<CGFloat> = 592 ... 664

    func fit(_ items: [ClosedRange<CGFloat>], preferred: CGFloat = 640) -> CGFloat {
        MenuBarFit.width(preferred: preferred, in: range, items: items)
    }

    @Test func noItemsKeepsThePreferredWidth() {
        #expect(fit([]) == 640)
    }

    @Test func edgeAlreadyInAGapStays() {
        // The edge (320 from the centre) ends before an icon at 330.
        #expect(fit([200 ... 224, 330 ... 354]) == 640)
    }

    @Test func coversAnIconWhenThatIsCloser() {
        // Ending before the icon would be 20 off, covering it plus the margin only 2.
        #expect(fit([300 ... 318]) == 644)
    }

    @Test func leavesAnIconOutWhenThatIsCloser() {
        #expect(fit([310 ... 334]) == 620)
    }

    @Test func tieGoesToTheNarrowerWidth() {
        // Before the icon is 10 off, past it plus the margin too.
        #expect(fit([310 ... 326]) == 620)
    }

    @Test func iconsLeftOfTheNotchAreMirrored() {
        #expect(fit([-318 ... -300]) == 644)
        #expect(fit([-334 ... -310]) == 620)
    }

    @Test func bothSidesMustFit() {
        // Right allows up to 300, the left icon then needs at most 296.
        #expect(fit([300 ... 330, -340 ... -296]) == 592)
    }

    @Test func wideItemAcrossTheWholeRangeKeepsThePreferredWidth() {
        // Like a clock with text: no width in range avoids cutting it.
        #expect(fit([280 ... 340]) == 640)
    }

    @Test func touchingFramesAreSplitAtTheSeam() {
        // Frames overlapping by 2 pt (each includes its own padding): the seam between them counts.
        #expect(fit([284 ... 326, 324 ... 358]) == 650)
    }

    @Test func framesOverlappingMoreThanTheMarginFormOneBlock() {
        // No seam at 315: nothing in range fits, so the width stays.
        #expect(fit([290 ... 320, 310 ... 340]) == 640)
    }

    @Test func measuredMenuBar() {
        // Menu extras right of the notch on a 14" MacBook Pro (notch centre at x 756, 27.10.):
        // ChatGPT, Starnotch, Jamie, Claude, Grammarly, Notion, battery, Wi-Fi.
        let frames: [ClosedRange<CGFloat>] = [
            938 ... 962, 976 ... 1000, 1006 ... 1042, 1040 ... 1082,
            1080 ... 1114, 1112 ... 1146, 1153 ... 1179, 1195 ... 1217,
        ]
        let items = frames.map { ($0.lowerBound - 756) ... ($0.upperBound - 756) }
        // 640 would end inside Claude's icon (284...326); the seam to Grammarly is at 325.
        #expect(fit(items) == 650)
    }

    @Test func edgesOfOneSide() {
        let edges = MenuBarFit.edges([10 ... 20, 30 ... 40, 39 ... 50])
        #expect(edges == [0 ... 10, 24 ... 30, 39.5 ... 39.5, 54 ... .infinity])
        #expect(MenuBarFit.edges([]) == [0 ... .infinity])
    }
}
