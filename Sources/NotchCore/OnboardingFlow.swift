/// The first-run steps in order: one calm card each. A step this Mac can't use (no music player,
/// no notes connector) is left out of the flow, but can still be opened by hand. The order is the
/// order of the cases; the numbers stay as launch flags know them, so the AI apps' step, added
/// later, has the next free one.
public enum OnboardingStep: Int, CaseIterable, Sendable {
    case tara = 0, agents, calendar, music, meetings, brain, notes
    /// Tara's memory in the user's AI apps.
    case memory = 8
    case tools = 7

    /// Nothing the notch needs is missing without it: marked "Optional" with "Skip for now".
    public var isOptional: Bool {
        switch self {
        case .music, .meetings, .notes, .memory: true
        default: false
        }
    }

    /// Where the step stands in the flow.
    public var position: Int { Self.allCases.firstIndex(of: self) ?? 0 }
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
        steps.first { $0.position > step.position }
    }

    /// The shown step before; nil on the first one.
    public func previous(before step: OnboardingStep) -> OnboardingStep? {
        steps.last { $0.position < step.position }
    }

    /// The step a launch flag or a menu entry asks for: a hidden one leads to the next shown step.
    public func resolve(_ step: OnboardingStep) -> OnboardingStep {
        hidden.contains(step) ? next(after: step) ?? steps.last ?? step : step
    }
}
