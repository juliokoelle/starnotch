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

    @Test func everyTabHasASwitch() {
        // A tab missing from the gallery would be off on a fresh install with no way to turn it on.
        #expect(Set(ToolSwitches.tabs + [.tools]) == Set(ModuleKind.allCases))
        #expect(ToolSwitches.tabs.count == Set(ToolSwitches.tabs).count)
        #expect(ToolSwitches.known.count == ModuleKind.allCases.count + ToolFeature.allCases.count)
    }

    @Test func toolsAddedInALaterVersionStartOff() {
        let isolated = IsolatedSettings()
        var everything = SwitcherSettings()
        everything.disabledModules = []
        everything.disabledFeatures = []
        isolated.store.save(everything)
        // The same version: nothing changes.
        for item in ToolSwitches.gallery { #expect(ToolSwitches.isOn(item, in: isolated.store.load())) }
        // Saved by a version without System and Quick capture.
        isolated.editSaved { $0["knownTools"] = ToolSwitches.known.filter { $0 != "module.system" && $0 != "feature.quickCapture" } }
        let loaded = isolated.store.load()
        #expect(!ToolSwitches.isOn(.module(.system), in: loaded))
        #expect(!ToolSwitches.isOn(.quickCapture, in: loaded))
        #expect(ToolSwitches.isOn(.module(.meeting), in: loaded))
        #expect(ToolSwitches.isOn(.clipboard, in: loaded))
        #expect(loaded.knownTools == ToolSwitches.known)
    }

    @Test func wheelOffersOnlyTabsThatAreOn() {
        var settings = SwitcherSettings()
        // The default layout has Dictation and Today, both off on a fresh install.
        for slot in SlotPosition.allCases {
            if case .module(let kind) = settings.wheelItem(at: slot) {
                #expect(ToolSwitches.isOn(.module(kind), in: settings))
            }
        }
        #expect(settings.wheelItem(at: .top) == .module(.agents))
        #expect(settings.wheelSlots == [.top, .bottom])
        ToolSwitches.set(.module(.today), on: true, in: &settings)
        #expect(settings.wheelItem(at: .left) == .module(.today))
        #expect(settings.wheelSlots == [.top, .bottom, .left])
    }

    @Test func musicExtrasLeaveTheMusicTabAlone() {
        var settings = SwitcherSettings()
        ToolSwitches.set(.lyricsOnHover, on: true, in: &settings)
        // Lyrics on hover needs the lyrics.
        #expect(ToolSwitches.isOn(.lyrics, in: settings))
        ToolSwitches.set(.appVolume, on: true, in: &settings)
        ToolSwitches.set(.lyrics, on: false, in: &settings)
        ToolSwitches.set(.appVolume, on: false, in: &settings)
        #expect(!ToolSwitches.isOn(.lyricsOnHover, in: settings))
        // Unlike the Tools tab, Music has its own content and stays on.
        #expect(ToolSwitches.isOn(.module(.nowPlaying), in: settings))
        // Music off: its extras are off with it.
        ToolSwitches.set(.lyrics, on: true, in: &settings)
        ToolSwitches.set(.module(.nowPlaying), on: false, in: &settings)
        #expect(!ToolSwitches.isOn(.lyrics, in: settings))
    }
}
