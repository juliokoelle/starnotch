import Testing
import TestSupport
@testable import NotchCore

@Suite struct OnboardingFlowTests {
    @Test func everyStepShowsByDefault() {
        let flow = OnboardingFlow()
        #expect(flow.steps == OnboardingStep.allCases)
        #expect(flow.previous(before: .tara) == nil)
        #expect(flow.next(after: .tools) == nil)
        #expect(flow.next(after: .agents) == .calendar)
    }

    @Test func hiddenStepsAreSkippedBothWays() {
        let flow = OnboardingFlow(hidden: [.music, .notes, .memory])
        #expect(flow.steps == [.tara, .agents, .calendar, .meetings, .brain, .tools])
        #expect(flow.next(after: .calendar) == .meetings)
        #expect(flow.previous(before: .meetings) == .calendar)
        #expect(flow.next(after: .brain) == .tools)
        #expect(flow.previous(before: .tools) == .brain)
    }

    @Test func aHiddenStepAskedForLeadsToTheNextShownOne() {
        let flow = OnboardingFlow(hidden: [.music, .notes])
        #expect(flow.resolve(.notes) == .memory)
        let noApps = OnboardingFlow(hidden: [.music, .notes, .memory])
        #expect(noApps.resolve(.notes) == .tools)
        #expect(noApps.resolve(.memory) == .tools)
        #expect(flow.resolve(.music) == .meetings)
        #expect(flow.resolve(.agents) == .agents)
        // Opened by hand anyway, Back and Continue still lead into the shown steps.
        #expect(flow.next(after: .music) == .meetings)
        #expect(flow.previous(before: .music) == .calendar)
    }

    @Test func optionalStepsAreTheOnesTheNotchDoesWithout() {
        let optional = OnboardingStep.allCases.filter(\.isOptional)
        #expect(optional == [.music, .meetings, .notes, .memory])
    }

    @Test func theAIAppsComeAfterTheNotesAndBeforeTheTools() {
        let flow = OnboardingFlow()
        #expect(flow.next(after: .notes) == .memory)
        #expect(flow.next(after: .memory) == .tools)
        #expect(flow.previous(before: .tools) == .memory)
        #expect(flow.steps.last == .tools)
        #expect(OnboardingFlow(hidden: [.notes]).previous(before: .memory) == .brain)
    }

    @Test func stepNumbersStayStableForLaunchFlags() {
        // `--onboarding-step N` and the palette's setup rows use these numbers.
        #expect(OnboardingStep(rawValue: 0) == .tara)
        #expect(OnboardingStep(rawValue: 1) == .agents)
        #expect(OnboardingStep(rawValue: 7) == .tools)
        #expect(OnboardingStep(rawValue: 8) == .memory)
    }
}
