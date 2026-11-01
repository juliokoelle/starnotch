import Testing
import TestSupport
@testable import NotchCore

@Suite struct AllToolsTests {
    private let ready: (ModuleKind) -> TabAvailability = { _ in .ready }

    @Test func everyToolOnceInItsAreaInOrder() {
        var everything = SwitcherSettings()
        everything.disabledModules = []
        everything.disabledFeatures = []
        everything.appleNotes = true
        let sections = AllTools.sections(settings: everything, available: ready)
        #expect(sections.map(\.area) == AllToolsArea.allCases)
        #expect(sections.flatMap(\.tiles).map(\.tool) == AllToolsArea.allCases.flatMap { area in AllTool.allCases.filter { $0.area == area } })
        #expect(Set(sections.flatMap(\.tiles).map(\.tool)) == Set(AllTool.allCases))
        #expect(sections.flatMap(\.tiles).allSatisfy { $0.state == .on })
        #expect(sections.first?.tiles.map(\.tool) == [.agents, .agentsInbox, .palette])
        #expect(sections.last?.tiles.map(\.tool) == [.system, .keepAwake, .watchMode, .dashboard, .settings])
    }

    @Test func aFreshInstallShowsTheCoreOnAndTheRestToTurnOn() {
        let settings = SwitcherSettings()
        let state = { AllTools.state(of: $0, in: settings, available: ready) }
        // Always there, the core tabs, and the teleprompter, which asks for nothing before it starts.
        for tool in [AllTool.palette, .joinMeeting, .watchMode, .settings, .dashboard, .agents, .agentsInbox, .calendar, .music, .prompter] {
            #expect(state(tool) == .on)
        }
        for tool in [AllTool.quickCapture, .captureInbox, .askTara, .meeting, .today, .clipboard, .downloads, .keepAwake, .appleNotes] {
            #expect(state(tool) == .off)
        }
        // The calendar's "+" is on by default, the camera check too.
        #expect(state(.addEvent) == .on)
        #expect(state(.checkCamera) == .on)
    }

    @Test func turningOnEveryNeedSwitchesATileOn() {
        for tool in AllTool.allCases {
            var settings = SwitcherSettings()
            settings.cameraCheck = false
            settings.addInNotch = false
            for need in tool.needs { AllTools.set(need, on: true, in: &settings) }
            #expect(AllTools.state(of: tool, in: settings, available: ready) == .on, "\(tool)")
        }
    }

    @Test func toolsWithSwitchesOfTheirOwnNeedThemToo() {
        var settings = SwitcherSettings()
        ToolSwitches.set(.notes, on: true, in: &settings)
        #expect(AllTools.state(of: .notepad, in: settings, available: ready) == .on)
        #expect(AllTools.state(of: .appleNotes, in: settings, available: ready) == .off)
        settings.appleNotes = true
        #expect(AllTools.state(of: .appleNotes, in: settings, available: ready) == .on)
        settings.cameraCheck = false
        #expect(AllTools.state(of: .checkCamera, in: settings, available: ready) == .off)
        #expect(AllTools.state(of: .calendar, in: settings, available: ready) == .on)
        // The calendar off takes its actions along.
        ToolSwitches.set(.module(.calendar), on: false, in: &settings)
        #expect(AllTools.state(of: .addEvent, in: settings, available: ready) == .off)
        #expect(AllTools.state(of: .addReminder, in: settings, available: ready) == .off)
    }

    @Test func aTabMissingOnThisMacMakesItsToolsUnavailable() {
        var settings = SwitcherSettings()
        settings.disabledModules = []
        let noWispr: (ModuleKind) -> TabAvailability = { $0 == .dictation ? .missing : $0 == .today ? .asks : .ready }
        #expect(AllTools.state(of: .dictation, in: settings, available: noWispr) == .unavailable)
        // Today asks for Reminders on Turn on: off until then, even with its switch on.
        #expect(AllTools.state(of: .today, in: settings, available: noWispr) == .off)
        // Tools of the Tools tab and those outside the tabs never depend on a tab.
        #expect(AllTool.clipboard.tabs == [.tools])
        #expect(AllTool.palette.tabs.isEmpty)
        #expect(AllTool.prompter.tabs.isEmpty)
        #expect(AllTool.addReminder.tabs == [.calendar])
    }

    @Test func missingToolsAndHiddenOffToolsLeaveTheGrid() {
        var settings = SwitcherSettings()
        let all = AllTools.sections(settings: settings, missing: [.dashboard, .captureInbox], available: ready).flatMap(\.tiles).map(\.tool)
        #expect(!all.contains(.dashboard))
        #expect(!all.contains(.captureInbox))
        #expect(all.contains(.quickCapture))
        // Off tools hidden: only what is on, and an area with nothing on is gone.
        settings.allToolsShowsOff = false
        let sections = AllTools.sections(settings: settings, available: ready)
        #expect(sections.flatMap(\.tiles).allSatisfy { $0.state == .on })
        #expect(!sections.flatMap(\.tiles).map(\.tool).contains(.quickCapture))
        #expect(sections.flatMap(\.tiles).map(\.tool).contains(.prompter))
        settings.disabledModules += [.nowPlaying]
        ToolSwitches.set(.prompter, on: false, in: &settings)
        #expect(!AllTools.sections(settings: settings, available: ready).map(\.area).contains(.media))
    }

    @Test func theTabIsOnForEveryoneAndStaysLast() {
        #expect(ToolSwitches.isOn(.module(.allTools), in: SwitcherSettings()))
        // Saved by a version without it: on all the same; switched off, it stays off.
        let isolated = IsolatedSettings()
        isolated.store.save(SwitcherSettings())
        isolated.editSaved { $0["knownTools"] = ToolSwitches.known.filter { $0 != "module.allTools" } }
        var loaded = isolated.store.load()
        #expect(ToolSwitches.isOn(.module(.allTools), in: loaded))
        ToolSwitches.set(.module(.allTools), on: false, in: &loaded)
        isolated.store.save(loaded)
        #expect(!ToolSwitches.isOn(.module(.allTools), in: isolated.store.load()))
        // Settings from before the stamp have it too.
        isolated.editSaved { $0.removeValue(forKey: "knownTools"); $0["disabledModules"] = [String]() }
        #expect(ToolSwitches.isOn(.module(.allTools), in: isolated.store.load()))
        // Last whatever the saved order says.
        let kinds: [ModuleKind] = [.agents, .allTools, .calendar, .system]
        #expect(ModuleOrder.sorted(kinds, by: []) == [.agents, .calendar, .system, .allTools])
        #expect(ModuleOrder.sorted(kinds, by: [.allTools, .system]) == [.system, .agents, .calendar, .allTools])
        #expect(ToolSwitches.tabs.last == .allTools)
    }

    @Test func showingOffToolsIsOnByDefaultAndSaved() {
        #expect(SwitcherSettings().allToolsShowsOff)
        let isolated = IsolatedSettings()
        var settings = SwitcherSettings()
        settings.allToolsShowsOff = false
        isolated.store.save(settings)
        #expect(!isolated.store.load().allToolsShowsOff)
        // Older settings without the key show them.
        isolated.editSaved { $0.removeValue(forKey: "allToolsShowsOff") }
        #expect(isolated.store.load().allToolsShowsOff)
    }

    @Test func arrowsWalkTheGrid() {
        // Rows of three: [0 1 2] [3 4] | [5 6 7] [8] | [9]
        let counts = [5, 4, 1]
        func move(_ index: Int?, _ step: AllToolsGrid.Step) -> Int? { AllToolsGrid.move(index, step, counts: counts, columns: 3) }
        #expect(move(nil, .down) == 0)
        #expect(move(nil, .up) == 0)
        #expect(move(0, .right) == 1)
        #expect(move(2, .right) == 3)          // on into the next row
        #expect(move(0, .left) == 0)           // stays at the edge
        #expect(move(9, .right) == 9)
        #expect(move(1, .down) == 4)
        #expect(move(2, .down) == 4)           // the shorter row's last tile
        #expect(move(4, .down) == 6)           // into the next section, same column
        #expect(move(6, .down) == 8)
        #expect(move(8, .down) == 9)
        #expect(move(9, .down) == 9)
        #expect(move(5, .up) == 3)
        #expect(move(7, .up) == 4)
        #expect(move(1, .up) == 1)
        #expect(move(42, .down) == 0)          // a tile that went away: start over
        #expect(AllToolsGrid.move(nil, .down, counts: [], columns: 3) == nil)
    }
}
