/// The first-run steps in order: one calm card each. A step this Mac can't use (no music player,
/// no notes connector) is left out of the flow, but can still be opened by hand.
public enum OnboardingStep: Int, CaseIterable, Sendable {
    case tara, agents, calendar, music, meetings, brain, notes, tools

    /// Nothing the notch needs is missing without it: marked "Optional" with "Skip for now".
    public var isOptional: Bool {
        switch self {
        case .music, .meetings, .notes: true
        default: false
        }
    }
}

/// Which steps show, and where Back and Continue lead from any of them.
public struct OnboardingFlow: Equatable, Sendable {
    public var hidden: Set<OnboardingStep>

    public init(hidden: Set<OnboardingStep> = []) {
        self.hidden = hidden
    }

    public var steps: [OnboardingStep] { OnboardingStep.allCases.filter { !hidden.contains($0) } }

    /// The next shown step; nil after the last one (the flow is finished).
    public func next(after step: OnboardingStep) -> OnboardingStep? {
        steps.first { $0.rawValue > step.rawValue }
    }

    /// The shown step before; nil on the first one.
    public func previous(before step: OnboardingStep) -> OnboardingStep? {
        steps.last { $0.rawValue < step.rawValue }
    }

    /// The step a launch flag or a menu entry asks for: a hidden one leads to the next shown step.
    public func resolve(_ step: OnboardingStep) -> OnboardingStep {
        hidden.contains(step) ? next(after: step) ?? steps.last ?? step : step
    }
}
