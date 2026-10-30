import Testing
import TestSupport
@testable import NotchCore

/// What's new: CHANGELOG.md as days, themes and changes with their kind.
@Suite struct ChangelogTests {
    let text = """
    # Changelog

    What changed, newest first.

    ## 29 October 2026

    ### Dashboard
    - **New:** The Dashboard, with a `sidebar`.
    - **Improved:** Home is calmer.

    ### Characters
    - **Changed:** Licenses.

    ## 28 October 2026

    ### Notch
    - **Fixed:** The ears stay clear.
    - Something without a kind.

    ## Empty day
    """

    @Test func readsDaysThemesAndKinds() {
        let days = Changelog.parse(text)
        #expect(days.map(\.title) == ["29 October 2026", "28 October 2026"])
        #expect(days[0].groups.map(\.title) == ["Dashboard", "Characters"])
        #expect(days[0].groups[0].items == [.init(kind: .new, text: "The Dashboard, with a `sidebar`."),
                                            .init(kind: .improved, text: "Home is calmer.")])
        #expect(days[1].groups[0].items.map(\.kind) == [.fixed, .changed])
        #expect(UTC.string(days[0].date.map { UTC.calendar.startOfDay(for: $0) }) != "nil")
    }

    @Test func theRepositoryChangelogParses() throws {
        let days = Changelog.parse(try Fixtures.repoFile("CHANGELOG.md"))
        #expect(days.count > 3)
        #expect(days.allSatisfy { $0.date != nil })
        #expect(days.flatMap(\.groups).flatMap(\.items).contains { $0.kind == .new })
    }
}
