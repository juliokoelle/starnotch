import Testing
@testable import NotchCore
import TestSupport

@Suite struct SettingsTests {
    @Test func defaultsWhenNothingStored() {
        let isolated = IsolatedSettings()
        let store = isolated.store
        let settings = store.load()
        #expect(settings == SwitcherSettings())
        #expect(settings.slots.count == 4)
        #expect(settings.activeSlot == nil)
        #expect(!settings.forceQuitEnabled)
    }

    @Test func roundTrip() {
        let isolated = IsolatedSettings()
        let store = isolated.store
        var settings = SwitcherSettings()
        settings[.top] = SlotApp(bundleID: "com.apple.calculator", name: "Calculator", path: "/System/Applications/Calculator.app")
        settings[.left] = SlotApp(bundleID: "com.apple.Stickies", name: "Stickies", path: "/System/Applications/Stickies.app")
        settings.activeSlot = .left
        settings.forceQuitEnabled = true
        settings.didShowAccessibilityIntro = true
        settings.mainCharacter = "ember"
        settings.colorway = "snow"
        settings.projects = ["api-server": ProjectStyle(character: "stone", hue: 70)]
        store.save(settings)

        let loaded = store.load()
        #expect(loaded == settings)
        // Apps replaced the modules on top and left; dictation (right) and calendar (bottom) stay.
        #expect(loaded.assignedSlots == [.top, .right, .bottom, .left])
        #expect(loaded.item(at: .right) == .module(.dictation))
        #expect(loaded.item(at: .top) == .app(settings[.top]!))
    }

    @Test func modulesAndAppsShareSlots() {
        var settings = SwitcherSettings()
        #expect(settings.item(at: .top) == .module(.agents))
        #expect(settings.item(at: .bottom) == .module(.calendar))
        settings[.bottom] = SlotApp(bundleID: "b", name: "B", path: "/B.app")
        #expect(settings.appBundleIDs == [nil, nil, "b", nil])
        settings[module: .bottom] = .today
        #expect(settings[.bottom] == nil)
        #expect(settings.position(of: .today) == .bottom)
    }

    @Test func toleratesOlderOrPartialData() {
        let isolated = IsolatedSettings()
        isolated.writeRaw(#"{"slots":[{"bundleID":"a","name":"A","path":"/A.app"},null,{"bundleID":"c","name":"C","path":"/C.app"}],"activeSlot":0}"#)

        let loaded = isolated.store.load()
        #expect(loaded.slots.count == 4)
        // Settings from before modules: the default modules take over, old notch apps are dropped.
        #expect(loaded[.top] == nil)
        #expect(loaded.item(at: .top) == .module(.agents))
        #expect(loaded[.bottom] == nil)
        #expect(loaded.mainCharacter == "")
        #expect(loaded.didOnboard)                 // saved before onboarding existed
        #expect(loaded.colorway == nil)
        #expect(loaded.activeSlot == SlotPosition.top)
        #expect(loaded.holdDuration == 0.25)
        #expect(loaded.modules == ModuleKind.defaultLayout)
        // Saved before the Tools gallery: every tool the gallery started with stays on, the brain
        // is the agent's pick. Tools added since (lyrics, volume per app) start off all the same,
        // but for those that start on with their tab.
        let stamp = Set(ToolSwitches.knownBeforeStamp)
        #expect(loaded.disabledModules.allSatisfy { !stamp.contains("module.\($0.rawValue)") })
        #expect(Set(loaded.disabledFeatures) == Set(ToolFeature.allCases.filter {
            !stamp.contains("feature.\($0.rawValue)") && !ToolSwitches.startsOn.contains($0)
        }))
        #expect(loaded.disabledFeatures.contains(.lyrics) && loaded.disabledFeatures.contains(.appVolume))
        #expect(loaded.brain == .auto)
    }

    @Test func quietEarsForNewAndExistingUsers() {
        // A fresh install: just Tara beside the notch.
        #expect(!SwitcherSettings().detailedEars)
        // Saved before the switch, with the ears set to always: still the quiet look.
        let isolated = IsolatedSettings()
        isolated.writeRaw(#"{"earsMode":"always","didOnboard":true}"#)
        let loaded = isolated.store.load()
        #expect(loaded.earsMode == .always)
        #expect(!loaded.detailedEars)
        // The richer ears stay an opt-in that is kept.
        var settings = loaded
        settings.detailedEars = true
        isolated.store.save(settings)
        #expect(isolated.store.load().detailedEars)
    }

    @Test func islandLookAndMeetingQuiet() {
        // Saved before these settings: the volume bar off, quiet in meetings on, the island as before.
        let isolated = IsolatedSettings()
        isolated.writeRaw(#"{"didOnboard":true,"islandDisplay":"pointer"}"#)
        let old = isolated.store.load()
        #expect(!old.levelHUD && old.meetingQuiet && !old.islandOutline)
        #expect(old.islandWidthScale == 1 && old.islandHeightScale == 1)
        #expect(old.islandDisplay == .pointer)
        var settings = old
        settings.levelHUD = true
        settings.meetingQuiet = false
        settings.islandDisplay = .all
        settings.islandWidthScale = 1.2
        settings.islandHeightScale = 0.9
        settings.islandOutline = true
        isolated.store.save(settings)
        #expect(isolated.store.load() == settings)
    }

    @Test func toolsGalleryAndBrainRoundTrip() {
        let isolated = IsolatedSettings()
        var settings = SwitcherSettings()
        settings.disabledFeatures = [.keepAwake]
        settings.brain = .claudeCode
        isolated.store.save(settings)
        let loaded = isolated.store.load()
        #expect(loaded.disabledFeatures == [.keepAwake])
        #expect(loaded.brain == .claudeCode)
        #expect(TaraBrain.claudeCode.rawValue == "claude-code")
    }

    @Test func notchOpeningAndTaraBesideRoundTrip() {
        let isolated = IsolatedSettings()
        var settings = SwitcherSettings()
        // Defaults: a click opens, the last tab comes back, Tara shows when something is up.
        #expect(settings.hoverOpen == .click && settings.hoverOpen.seconds == nil)
        #expect(settings.reopenLastTab)
        #expect(settings.taraBeside == .activity)
        settings.hoverOpen = .half
        settings.reopenLastTab = false
        settings.taraBeside = .always
        #expect(settings.eyeStyle == .lines)
        settings.eyeStyle = .round
        isolated.store.save(settings)
        let loaded = isolated.store.load()
        #expect(loaded.hoverOpen.seconds == 0.5)
        #expect(!loaded.reopenLastTab)
        #expect(loaded.eyeStyle == .round)
        #expect(loaded.taraBeside == .always && loaded.taraAlways && loaded.earsMode == .always)
        var never = loaded
        never.taraBeside = .never
        #expect(never.earsMode == .never && !never.taraAlways)
    }

    @Test func musicModesAndCameraCheckStartOn() {
        // On for a fresh install and for settings saved before the switches existed.
        #expect(SwitcherSettings().musicModes && SwitcherSettings().cameraCheck)
        let isolated = IsolatedSettings()
        isolated.writeRaw(#"{"didOnboard":true}"#)
        #expect(isolated.store.load().musicModes && isolated.store.load().cameraCheck)
        var settings = SwitcherSettings()
        settings.musicModes = false
        settings.cameraCheck = false
        isolated.store.save(settings)
        #expect(!isolated.store.load().musicModes && !isolated.store.load().cameraCheck)
    }

    @Test func addingInTheNotchIsOnAndAppleNotesOffUntilChosen() {
        let isolated = IsolatedSettings()
        var settings = SwitcherSettings()
        #expect(settings.addInNotch && !settings.appleNotes && settings.appleNotesCapture == nil)
        settings.addInNotch = false
        settings.appleNotes = true
        settings.appleNotesCapture = AppleNotesFolder(id: "x-coredata://F/ICFolder/p7", name: "Inbox", account: "iCloud")
        isolated.store.save(settings)
        let loaded = isolated.store.load()
        #expect(!loaded.addInNotch && loaded.appleNotes && loaded.appleNotesCapture?.label == "iCloud › Inbox")
        // Saved before these existed: adding stays on, Apple Notes off.
        isolated.editSaved { json in
            json.removeValue(forKey: "addInNotch")
            json.removeValue(forKey: "appleNotes")
            json.removeValue(forKey: "appleNotesCapture")
        }
        let older = isolated.store.load()
        #expect(older.addInNotch && !older.appleNotes && older.appleNotesCapture == nil)
    }

    @Test func corruptDataFallsBackToDefaults() {
        let isolated = IsolatedSettings()
        isolated.writeRaw("not json")
        #expect(isolated.store.load() == SwitcherSettings())
    }

    @Test func knownNotchAppMatching() {
        #expect(KnownNotchApps.matches(name: "The Boring Notch", bundleID: nil))
        #expect(KnownNotchApps.matches(name: "boringNotch", bundleID: "theboringteam.boringnotch"))
        #expect(KnownNotchApps.matches(name: "DynamicLake Pro", bundleID: nil))
        #expect(KnownNotchApps.matches(name: "Something", bundleID: "com.example.alcove"))
        #expect(!KnownNotchApps.matches(name: "Calculator", bundleID: "com.apple.calculator"))
    }
}
