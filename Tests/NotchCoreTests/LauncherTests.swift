import Testing
import TestSupport
@testable import NotchCore

@Suite struct LauncherTests {
    let notes = SlotApp(bundleID: "com.apple.Notes", name: "Notes", path: "/System/Applications/Notes.app")

    @Test func shortcutsListOutputBecomesNames() {
        let output = "Morning routine\n\n  Log water  \nMorning routine\nTurn on Do Not Disturb\n"
        #expect(Launcher.shortcutNames(from: output) == ["Morning routine", "Log water", "Turn on Do Not Disturb"])
        #expect(Launcher.shortcutNames(from: "").isEmpty)
    }

    @Test func searchSkipsWhatIsPickedAndIgnoresCase() {
        let names = ["Morning routine", "Log water", "Mörning stretch"]
        let picked = [LauncherItem.shortcut("Log water")]
        #expect(Launcher.shortcuts(names, matching: "", besides: picked) == ["Morning routine", "Mörning stretch"])
        #expect(Launcher.shortcuts(names, matching: "morning", besides: picked) == ["Morning routine", "Mörning stretch"])
        #expect(Launcher.shortcuts(names, matching: "water", besides: picked).isEmpty)
    }

    @Test func addMoveAndRemoveKeepEachItemOnce() {
        var items: [LauncherItem] = []
        Launcher.add(.shortcut("Log water"), to: &items)
        Launcher.add(.app(notes), to: &items)
        Launcher.add(.shortcut("Log water"), to: &items)
        #expect(items.map(\.id) == ["shortcut:Log water", "app:com.apple.Notes"])
        Launcher.move("app:com.apple.Notes", by: -1, in: &items)
        #expect(items.map(\.name) == ["Notes", "Log water"])
        // At the top it stays.
        Launcher.move("app:com.apple.Notes", by: -1, in: &items)
        #expect(items.first?.name == "Notes")
        Launcher.remove("shortcut:Log water", from: &items)
        #expect(items == [.app(notes)])
    }

    @Test func aShortcutAndAnAppOfTheSameNameAreTwoItems() {
        var items: [LauncherItem] = []
        Launcher.add(.shortcut("Notes"), to: &items)
        Launcher.add(.app(notes), to: &items)
        #expect(items.count == 2)
    }

    @Test func theLauncherIsSavedWithTheSettings() {
        let isolated = IsolatedSettings()
        var settings = SwitcherSettings()
        settings.launcher = [.shortcut("Log water"), .app(notes)]
        isolated.store.save(settings)
        #expect(isolated.store.load().launcher == settings.launcher)
        // Saved before the launcher existed: an empty one.
        isolated.editSaved { $0["launcher"] = nil }
        #expect(isolated.store.load().launcher.isEmpty)
    }
}
