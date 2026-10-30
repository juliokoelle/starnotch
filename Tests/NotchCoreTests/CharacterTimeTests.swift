import Testing
import TestSupport
@testable import NotchCore

@Suite struct CharacterTimeTests {
    @Test func timePerCharacterFromItsProjects() {
        let projects = [ProjectTime(name: "notch", seconds: 7200, sessions: 3),
                        ProjectTime(name: "site", seconds: 1800, sessions: 1),
                        ProjectTime(name: "api", seconds: 3600, sessions: 2),
                        // Sessions without a folder count under the tool: no character's time.
                        ProjectTime(name: "Codex", seconds: 900, sessions: 1),
                        ProjectTime(name: "empty", seconds: 0, sessions: 1)]
        let cast = ["notch": "astra", "site": "astra", "api": "cat", "Codex": "cat", "empty": "moss"]
        let map = CharacterTime.together(projects, tools: ["Codex"]) { cast[$0] ?? "" }
        #expect(map["astra"] == CharacterTime.Together(seconds: 9000, sessions: 4))
        #expect(map["cat"] == CharacterTime.Together(seconds: 3600, sessions: 2))
        // No time, no entry: the page shows no number rather than a zero.
        #expect(map["moss"] == nil)
        #expect(CharacterTime.together([], tools: []) { _ in "astra" }.isEmpty)
    }

    @Test func projectOrder() {
        let order = CharacterTime.order(["b", "a", "home", "live", "busy"], home: "home", live: ["live"],
                                        seconds: ["busy": 600, "live": 10, "a": 0])
        #expect(order == ["home", "live", "busy", "a", "b"])
        #expect(CharacterTime.order([], home: "", live: [], seconds: [:]).isEmpty)
    }
}
