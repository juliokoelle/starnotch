import Testing
import TestSupport
@testable import NotchCore

@Suite struct ToolSwitchesTests {
    @Test func freshInstallHasOnlyTheCore() {
        let settings = SwitcherSettings()
        for kind in ToolSwitches.core { #expect(ToolSwitches.isOn(.module(kind), in: settings)) }
        for kind in [ModuleKind.meeting, .today, .system, .dictation, .tools] {
            #expect(!ToolSwitches.isOn(.module(kind), in: settings))
        }
        for feature in ToolFeature.allCases { #expect(!ToolSwitches.isOn(feature, in: settings)) }
    }

    @Test func olderSettingsKeepEveryTool() {
        var settings = SwitcherSettings()
        settings.disabledModules = []
        settings.disabledFeatures = []
        for item in ToolSwitches.gallery { #expect(ToolSwitches.isOn(item, in: settings)) }
    }

    @Test func aSmallToolBringsItsTabAlone() {
        var settings = SwitcherSettings()
        ToolSwitches.set(.clipboard, on: true, in: &settings)
        #expect(ToolSwitches.isOn(.clipboard, in: settings))
        #expect(!settings.disabledModules.contains(.tools))
        #expect(!ToolSwitches.isOn(.timers, in: settings))
        #expect(!ToolSwitches.isOn(.shelf, in: settings))
        // The last tool of the tab off: the tab goes too.
        ToolSwitches.set(.clipboard, on: false, in: &settings)
        #expect(settings.disabledModules.contains(.tools))
    }

    @Test func tabSwitchedOffAsAWholeComesBackOneToolAtATime() {
        var settings = SwitcherSettings()
        settings.disabledModules = [.tools]
        settings.disabledFeatures = []
        #expect(!ToolSwitches.isOn(.timers, in: settings))
        ToolSwitches.set(.timers, on: true, in: &settings)
        #expect(ToolSwitches.isOn(.timers, in: settings))
        #expect(!ToolSwitches.isOn(.clipboard, in: settings))
        #expect(!ToolSwitches.isOn(.shelf, in: settings))
    }

    @Test func converterNeedsTheShelf() {
        var settings = SwitcherSettings()
        ToolSwitches.set(.imageConverter, on: true, in: &settings)
        #expect(ToolSwitches.isOn(.imageConverter, in: settings))
        #expect(ToolSwitches.isOn(.shelf, in: settings))
        #expect(!ToolSwitches.isOn(.clipboard, in: settings))
        // Shelf off: the converter has nothing to work on, and the tab has nothing left.
        ToolSwitches.set(.shelf, on: false, in: &settings)
        #expect(!ToolSwitches.isOn(.imageConverter, in: settings))
        #expect(settings.disabledModules.contains(.tools))
    }

    @Test func toolsOutsideTheTabsLeaveTheTabsAlone() {
        var settings = SwitcherSettings()
        let before = settings.disabledModules
        ToolSwitches.set(.keepAwake, on: true, in: &settings)
        ToolSwitches.set(.quickCapture, on: true, in: &settings)
        #expect(ToolSwitches.isOn(.keepAwake, in: settings))
        #expect(ToolSwitches.isOn(.quickCapture, in: settings))
        #expect(settings.disabledModules == before)
    }

    @Test func tabsSwitchThroughDisabledModules() {
        var settings = SwitcherSettings()
        ToolSwitches.set(.module(.meeting), on: true, in: &settings)
        #expect(!settings.disabledModules.contains(.meeting))
        ToolSwitches.set(.module(.agents), on: false, in: &settings)
        #expect(settings.disabledModules.contains(.agents))
        #expect(!ToolSwitches.gallery.contains(.module(.tools)))
    }
}
