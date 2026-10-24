import Testing
@testable import NotchCore

@Suite struct LookPolicyTests {
    let all = Set(PerformanceLevel.allCases)

    /// A non-tintable character (the cat) is never tinted, in any mode, at any level, with or
    /// without a saved colour; its eyes follow the effort whenever the level is known.
    @Test func nonTintableIsNeverTinted() {
        for colourBy in [ColourBy.performance, .session] {
            for customized in [false, true] {
                for level in [nil] + PerformanceLevel.allCases.map(Optional.some) {
                    let look = LookPolicy.look(tintable: false, colourBy: colourBy, level: level,
                                               customized: customized, levelLooks: all)
                    #expect(!look.tinted)
                    #expect(look.level == level)
                }
            }
        }
        // No look for the level (or unknown effort): base sprites, still untinted.
        let none = LookPolicy.look(tintable: false, colourBy: .session, level: .max, customized: true, levelLooks: [])
        #expect(none == LookPolicy.Look(tinted: false, level: nil))
    }

    @Test func tintableFollowsSettings() {
        #expect(LookPolicy.look(tintable: true, colourBy: .performance, level: .max, customized: false, levelLooks: all)
                == .init(tinted: true, level: .max))
        // A colour picked for the level, or colour by session: the scale's colour, not the own look.
        #expect(LookPolicy.look(tintable: true, colourBy: .performance, level: .max, customized: true, levelLooks: all)
                == .init(tinted: true, level: nil))
        #expect(LookPolicy.look(tintable: true, colourBy: .session, level: .max, customized: false, levelLooks: all)
                == .init(tinted: true, level: nil))
        #expect(LookPolicy.look(tintable: true, colourBy: .performance, level: nil, customized: false, levelLooks: all)
                == .init(tinted: true, level: nil))
    }
}
