import Testing
@testable import NotchCore

@Suite struct SwitchPlanTests {
    let slots: [String?] = ["app.alcove", "app.boring", nil, "app.atoll"]

    @Test func terminatesOnlyRunningOtherSlotApps() {
        let plan = SwitchPlan.make(
            slots: slots,
            selected: .right,
            running: ["app.alcove", "app.atoll", "com.apple.finder"]
        )
        #expect(plan == SwitchPlan(launch: "app.boring", terminate: ["app.alcove", "app.atoll"]))
    }

    @Test func neverTerminatesTheTarget() {
        let plan = SwitchPlan.make(slots: slots, selected: .top, running: ["app.alcove"])
        #expect(plan == SwitchPlan(launch: "app.alcove", terminate: []))
    }

    @Test func emptySlotHasNoPlan() {
        #expect(SwitchPlan.make(slots: slots, selected: .bottom, running: []) == nil)
    }

    @Test func duplicateAssignmentsAreTerminatedOnce() {
        let plan = SwitchPlan.make(slots: ["a", "b", "b", nil], selected: .top, running: ["b"])
        #expect(plan?.terminate == ["b"])
    }
}
