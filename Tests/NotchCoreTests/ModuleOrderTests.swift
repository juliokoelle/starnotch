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
}
