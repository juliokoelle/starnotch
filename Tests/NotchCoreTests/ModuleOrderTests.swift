import Testing
import TestSupport
@testable import NotchCore

@Suite struct ModuleOrderTests {
    @Test func sortsByTheSavedOrder() {
        let kinds: [ModuleKind] = [.agents, .today, .calendar, .system, .meeting]
        #expect(ModuleOrder.sorted(kinds, by: []) == kinds)
        #expect(ModuleOrder.sorted(kinds, by: [.meeting, .agents]) == [.meeting, .agents, .today, .calendar, .system])
        // Kinds not shown are ignored; the first mention wins.
        #expect(ModuleOrder.sorted([.agents, .system], by: [.dictation, .system, .agents, .system]) == [.system, .agents])
    }

    @Test func savedKeepsHiddenModules() {
        let previous: [ModuleKind] = [.dictation, .agents, .calendar]
        let saved = ModuleOrder.saved(visible: [.calendar, .agents], previous: previous)
        #expect(Array(saved.prefix(2)) == [.calendar, .agents])
        #expect(saved.firstIndex(of: .dictation)! < saved.firstIndex(of: .today)!)
        #expect(Set(saved) == Set(ModuleKind.allCases))
    }

    @Test func settingsRoundTrip() {
        let isolated = IsolatedSettings()
        var settings = SwitcherSettings()
        settings.moduleOrder = [.meeting, .agents]
        isolated.store.save(settings)
        #expect(isolated.store.load().moduleOrder == [.meeting, .agents])
        #expect(SwitcherSettings().moduleOrder.isEmpty)
    }

    @Test func toolTabsKeepTheirDraggedOrder() {
        let all = ["Clipboard", "Timer", "Shelf", "Notepad"]
        // The shelf is switched off: dragging the notepad first keeps the shelf after the timer.
        let saved = ModuleOrder.saved(visible: ["Notepad", "Clipboard", "Timer"], previous: [], all: all)
        #expect(saved == ["Notepad", "Clipboard", "Timer", "Shelf"])
        #expect(ModuleOrder.ordered(["Clipboard", "Timer", "Shelf"], by: saved) == ["Clipboard", "Timer", "Shelf"])
        #expect(ModuleOrder.ordered(all, by: saved) == saved)

        let isolated = IsolatedSettings()
        var settings = SwitcherSettings()
        settings.toolOrder = saved
        isolated.store.save(settings)
        #expect(isolated.store.load().toolOrder == saved)
        #expect(SwitcherSettings().toolOrder.isEmpty)
    }
}
