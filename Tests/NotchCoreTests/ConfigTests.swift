import Testing
import TestSupport
@testable import NotchCore

@Suite struct ConfigTests {
    let text = """
    # comment
    top = 1

    [agents]
    claude_dir = "~/.claude"   # trailing comment
    launchd_prefix = 'com.example.'
    show = true

    [characters]
    projects = ["notes:pebble", "api:stone"]
    ratio = 0.5

    [connectors.sample]
    url = "https://example.com/#anchor"
    big = 1_000
    """

    @Test func parsesSectionsAndValues() throws {
        let config = try NotchConfig.parse(text)
        #expect(config[""].int("top", default: 0) == 1)
        #expect(config["agents"].string("launchd_prefix") == "com.example.")
        #expect(config["agents"].bool("show", default: false))
        #expect(config["agents"].path("claude_dir", home: Bytes.url("/Users/test"))?.path == "/Users/test/.claude")
        #expect(config["characters"].strings("projects") == ["notes:pebble", "api:stone"])
        #expect(config["characters"].values["ratio"] == .double(0.5))
        #expect(config.connector("sample").url("url")?.absoluteString == "https://example.com/#anchor")
        #expect(config.connector("sample").int("big", default: 0) == 1000)
        // Missing keys and sections fall back.
        #expect(config["nothing"].string("x", default: "d") == "d")
        #expect(config["agents"].int("show", default: 7) == 7)
    }

    @Test func reportsBrokenLines() {
        #expect(throws: NotchConfig.ParseError.self) { try NotchConfig.parse("[agents\nx = 1") }
        #expect(throws: NotchConfig.ParseError.self) { try NotchConfig.parse("just words") }
        #expect(throws: NotchConfig.ParseError.self) { try NotchConfig.parse("x = \"open") }
        do {
            _ = try NotchConfig.parse("a = 1\nb = nope")
            Issue.record("expected an error")
        } catch let error as NotchConfig.ParseError {
            #expect(error.line == 2)
        } catch {
            Issue.record("wrong error")
        }
    }

    @Test func userConfigOverridesBuildDefaults() throws {
        var config = try NotchConfig.parse("[agents]\nlaunchd_prefix = \"com.build.\"\nclaude_dir = \"~/.claude\"")
        config.merge(try NotchConfig.parse("[agents]\nlaunchd_prefix = \"\"\n[api]\nport = 50000"))
        #expect(config["agents"].string("launchd_prefix") == "")
        #expect(config["agents"].string("claude_dir") == "~/.claude")
        #expect(config["api"].int("port", default: 0) == 50000)
    }

    @Test func commentedTemplateIsEmpty() throws {
        let config = try NotchConfig.parse("[general]\n# language = \"system\"\n")
        #expect(config["general"].values.isEmpty)
    }
}
