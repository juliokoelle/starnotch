import CoreGraphics
import Testing
@testable import NotchCore

@Suite struct PanelSizeTests {
    @Test func quickModulesOpenCompact() {
        #expect(ModuleKind.nowPlaying.panelSize == .compact)
        #expect(ModuleKind.dictation.panelSize == .compact)
        #expect(ModuleKind.tools.panelSize == .compact)
    }

    @Test func contentModulesOpenLarge() {
        for kind in [ModuleKind.agents, .today, .calendar, .system, .meeting] {
            #expect(kind.panelSize == .large)
        }
    }

    @Test func compactIsSmallerBothWays() {
        #expect(PanelSize.compact.width < PanelSize.large.width)
        #expect(PanelSize.compact.height < PanelSize.large.height)
    }

    @Test func rangeHoldsThePreferredWidth() {
        for size in PanelSize.allCases {
            #expect(size.widthRange.contains(size.width))
        }
    }

    @Test func compactNeverNarrows() {
        // The tab split in its header needs the full compact width.
        #expect(PanelSize.compact.widthRange.lowerBound == PanelSize.compact.width)
    }
}
