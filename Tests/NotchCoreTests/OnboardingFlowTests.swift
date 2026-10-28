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
        let flow = OnboardingFlow(hidden: [.music, .notes])
        #expect(flow.steps == [.tara, .agents, .calendar, .meetings, .brain, .tools])
        #expect(flow.next(after: .calendar) == .meetings)
        #expect(flow.previous(before: .meetings) == .calendar)
        #expect(flow.next(after: .brain) == .tools)
        #expect(flow.previous(before: .tools) == .brain)
    }

    @Test func aHiddenStepAskedForLeadsToTheNextShownOne() {
        let flow = OnboardingFlow(hidden: [.music, .notes])
        #expect(flow.resolve(.music) == .meetings)
        #expect(flow.resolve(.notes) == .tools)
        #expect(flow.resolve(.agents) == .agents)
        // Opened by hand anyway, Back and Continue still lead into the shown steps.
        #expect(flow.next(after: .music) == .meetings)
        #expect(flow.previous(before: .music) == .calendar)
    }

    @Test func optionalStepsAreTheOnesTheNotchDoesWithout() {
        let optional = OnboardingStep.allCases.filter(\.isOptional)
        #expect(optional == [.music, .meetings, .notes])
    }

    @Test func stepNumbersStayStableForLaunchFlags() {
        // `--onboarding-step N` and the palette's setup rows use these numbers.
        #expect(OnboardingStep(rawValue: 0) == .tara)
        #expect(OnboardingStep(rawValue: 1) == .agents)
        #expect(OnboardingStep(rawValue: 7) == .tools)
    }
}
