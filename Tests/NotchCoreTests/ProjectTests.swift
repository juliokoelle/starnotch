import Testing
import TestSupport
@testable import NotchCore

@Suite struct ProjectTests {
    let cast = ["pebble", "moss", "ember", "plum", "slate", "stone"]
    let defaults = ["notes": "pebble"]

    @Test func projectFromWorkingDirectory() {
        #expect(ProjectKey.project(cwd: "/Users/j/projects/notch") == "notch")
        #expect(ProjectKey.project(cwd: "/Users/j/projects/notch/.claude/worktrees/redesign") == "notch")
        #expect(ProjectKey.project(cwd: "/Users/j/Library/Mobile Documents/iCloud~md~obsidian/Documents/notes/") == "notes")
    }

    @Test func characterPerProject() {
        #expect(ProjectAssignment.character(project: "notes", styles: [:], characters: cast, defaults: defaults) == "pebble")
        let tools = ProjectAssignment.character(project: "api-server", styles: [:], characters: cast, defaults: defaults)
        #expect(tools != "pebble")
        #expect(tools == ProjectAssignment.character(project: "api-server", styles: [:], characters: cast.reversed(), defaults: defaults))
        // The user's pick wins, also over the default.
        let styles = ["notes": ProjectStyle(character: "ember"), "api-server": ProjectStyle(character: "stone")]
        #expect(ProjectAssignment.character(project: "notes", styles: styles, characters: cast, defaults: defaults) == "ember")
        #expect(ProjectAssignment.character(project: "api-server", styles: styles, characters: cast) == "stone")
        // A pick that no longer exists falls back.
        #expect(ProjectAssignment.character(project: "x", styles: ["x": ProjectStyle(character: "gone")], characters: cast) != "gone")
        // No characters at all: no crash, an empty id.
        #expect(ProjectAssignment.character(project: "x", styles: [:], characters: []) == "")
    }

    @Test func noTwoProjectsShareACharacter() {
        let projects = ["notes", "notch", "website", "cli-tool", "docs", "api-server"]
        let map = ProjectAssignment.characters(projects: projects, styles: [:], characters: cast, defaults: defaults)
        #expect(map["notes"] == "pebble")
        #expect(Set(map.values).count == projects.count)
        #expect(map == ProjectAssignment.characters(projects: projects.reversed(), styles: [:], characters: cast, defaults: defaults))
        let picked = ProjectAssignment.characters(projects: projects, styles: ["cli-tool": ProjectStyle(character: "stone")],
                                                  characters: cast, defaults: defaults)
        #expect(picked["cli-tool"] == "stone")
        #expect(picked.filter { $0.value == "stone" }.count == 1)
        // A fallback character: everyone without a pick or default shares it.
        let shared = ProjectAssignment.characters(projects: projects, styles: ["cli-tool": ProjectStyle(character: "stone")],
                                                  characters: cast, defaults: defaults, fallback: "plum")
        #expect(shared["notes"] == "pebble" && shared["cli-tool"] == "stone" && shared["docs"] == "plum" && shared["notch"] == "plum")
        #expect(ProjectAssignment.character(project: "docs", styles: [:], characters: cast, fallback: "plum") == "plum")
    }

    @Test func performanceLevels() {
        #expect(PerformanceLevel(effort: "max") == .max)
        #expect(PerformanceLevel(effort: "Ultra") == .ultra)
        #expect(PerformanceLevel(effort: "maximum") == .max)
        #expect(PerformanceLevel.defaultScale[.ultra] == "matte_black")
        #expect(PerformanceLevel(effort: "medium") == .medium)
        #expect(PerformanceLevel(effort: "weird") == nil)
        #expect(PerformanceLevel.defaultScale[.max] == "matte_black")
    }

    @Test func coloursByPerformanceAndSession() {
        let t1 = UTC.date("2026-10-22 08:00"), t2 = UTC.date("2026-10-22 09:00"), t3 = UTC.date("2026-10-22 10:00")
        let sessions = [SessionColours.Session(id: "notch", level: .max, started: t1),
                        SessionColours.Session(id: "cv", level: .medium, started: t2),
                        SessionColours.Session(id: "sim", level: .medium, started: t3),
                        SessionColours.Session(id: "x", level: nil, started: t3)]
        let byLevel = SessionColours.assign(sessions, by: .performance, scale: PerformanceLevel.defaultScale,
                                            sessionPalette: ["lavender", "mint", "sky_blue"])
        #expect(byLevel["notch"]?.colorway == "matte_black")
        #expect(byLevel["cv"]?.colorway == "mint")
        #expect(byLevel["sim"]?.colorway == "mint")
        #expect(byLevel["cv"]?.offset == 0)
        #expect(byLevel["sim"]?.offset == 12)          // same level: a subtle shift
        let custom = SessionColours.assign(sessions, by: .performance, scale: [.max: "chrome"], sessionPalette: [])
        #expect(custom["notch"]?.colorway == "chrome")
        let bySession = SessionColours.assign(sessions, by: .session, scale: [:], sessionPalette: ["a", "b", "c"])
        #expect(bySession["notch"]?.colorway == "a")
        #expect(bySession["cv"]?.colorway == "b")
    }
}
