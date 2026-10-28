import Testing
import TestSupport
@testable import NotchCore

@Suite struct PaletteTests {
    @Test func subsequenceInOrder() {
        #expect(FuzzyMatch.match("cal", in: "Calendar") != nil)
        #expect(FuzzyMatch.match("nxt", in: "Next") != nil)
        #expect(FuzzyMatch.match("cldr", in: "Calendar") != nil)
        // Order matters inside a word, and every character must be there.
        #expect(FuzzyMatch.match("lac", in: "Calendar") == nil)
        #expect(FuzzyMatch.match("xyz", in: "Calendar") == nil)
        #expect(FuzzyMatch.match("calendars", in: "Calendar") == nil)
    }

    @Test func caseAccentsAndWords() {
        #expect(FuzzyMatch.match("UBER", in: "Über uns") != nil)
        #expect(FuzzyMatch.match("ueber", in: "Über uns") == nil)
        // Each word of the query on its own, in any order.
        #expect(FuzzyMatch.match("awake keep", in: "Keep awake") != nil)
        #expect(FuzzyMatch.match("keep sleep", in: "Keep awake") == nil)
        // An empty query matches with no score.
        #expect(FuzzyMatch.match("  ", in: "Keep awake")?.score == 0)
    }

    @Test func highlightsTheMatchedCharacters() {
        #expect(FuzzyMatch.match("cal", in: "Calendar")?.positions == [0, 1, 2])
        // Word starts beat the first occurrence mid-word: "ka" is Keep Awake, not "kee-p a".
        #expect(FuzzyMatch.match("ka", in: "Keep awake")?.positions == [0, 5])
        // Camel case counts as a word start.
        #expect(FuzzyMatch.match("nm", in: "NowPlayingModule")?.positions == [0, 10])
        #expect(FuzzyMatch.match("awake keep", in: "Keep awake")?.positions == [0, 1, 2, 3, 5, 6, 7, 8, 9])
    }

    @Test func betterMatchesScoreHigher() {
        func score(_ query: String, _ text: String) -> Double { FuzzyMatch.match(query, in: text)?.score ?? -1 }
        // Prefix beats a match later in the text.
        #expect(score("cal", "Calendar") > score("cal", "Local calls"))
        // Consecutive beats scattered.
        #expect(score("time", "Timer") > score("time", "Toggle insomnia mode everywhere"))
        // Word starts beat mid-word letters.
        #expect(score("ka", "Keep awake") > score("ka", "Bookmarks"))
        // The whole title beats a longer one with the same start.
        #expect(score("today", "Today") > score("today", "Today's agenda"))
    }

    @Test func rankingByMatch() {
        let candidates = [
            PaletteCandidate(id: "a", title: "Local calls"),
            PaletteCandidate(id: "b", title: "Calendar"),
            PaletteCandidate(id: "c", title: "Clipboard"),
        ]
        let ranked = PaletteRanking.rank(candidates, query: "cal", usage: PaletteUsage(), now: UTC.date("2026-10-28 10:00"))
        #expect(ranked.map(\.index) == [1, 0])
        #expect(ranked.first?.highlights == [0, 1, 2])
    }

    @Test func keywordsMatchWithoutHighlights() {
        let candidates = [PaletteCandidate(id: "settings", title: "Settings", keywords: ["preferences"])]
        let ranked = PaletteRanking.rank(candidates, query: "pref", usage: PaletteUsage(), now: UTC.date("2026-10-28 10:00"))
        #expect(ranked.count == 1)
        #expect(ranked.first?.highlights == [])
    }

    @Test func usageLiftsEqualMatches() {
        let now = UTC.date("2026-10-28 10:00")
        let candidates = [
            PaletteCandidate(id: "session:a", title: "harbor · Speed up reports"),
            PaletteCandidate(id: "session:b", title: "harbor · Flaky export test"),
        ]
        var usage = PaletteUsage()
        usage.record("session:b", at: UTC.date("2026-10-28 09:00"))
        let ranked = PaletteRanking.rank(candidates, query: "harbor", usage: usage, now: now)
        #expect(ranked.map(\.index) == [1, 0])
        // With no query, what you used comes first, the rest keeps its order.
        let empty = PaletteRanking.rank(candidates + [PaletteCandidate(id: "tab:agents", title: "Agents")], query: "",
                                        usage: usage, now: now)
        #expect(empty.map(\.index) == [1, 0, 2])
    }

    @Test func usageDoesNotBeatAClearlyBetterMatch() {
        let now = UTC.date("2026-10-28 10:00")
        let candidates = [
            PaletteCandidate(id: "loop", title: "Toggle insomnia mode everywhere"),
            PaletteCandidate(id: "timer", title: "Timer"),
        ]
        var usage = PaletteUsage()
        for _ in 0..<3 { usage.record("loop", at: now) }
        #expect(PaletteRanking.rank(candidates, query: "timer", usage: usage, now: now).first?.index == 1)
    }

    @Test func frequencyAndRecency() {
        let now = UTC.date("2026-10-28 10:00")
        var usage = PaletteUsage()
        usage.record("often", at: now)
        usage.record("often", at: now)
        usage.record("often", at: now)
        usage.record("once", at: now)
        usage.record("old", at: UTC.date("2026-09-28 10:00"))
        usage.record("old", at: UTC.date("2026-09-28 10:00"))
        usage.record("old", at: UTC.date("2026-09-28 10:00"))
        #expect(usage.boost("often", now: now) > usage.boost("once", now: now))
        #expect(usage.boost("once", now: now) > usage.boost("old", now: now))
        #expect(usage.boost("never", now: now) == 0)
        #expect(usage.boost("often", now: now) <= 0.6)
        // A week later a pick counts half.
        let week = UTC.date("2026-11-04 10:00")
        #expect(abs(usage.boost("once", now: week) - usage.boost("once", now: now) / 2) < 0.0001)
    }

    @Test func usageStaysSmall() {
        let now = UTC.date("2026-10-28 10:00")
        var usage = PaletteUsage()
        for _ in 0..<3 { usage.record("kept", at: now) }
        for n in 0..<(PaletteUsage.limit + 20) { usage.record("item-\(n)", at: now) }
        #expect(usage.entries.count == PaletteUsage.limit)
        // The least used go first; the one picked three times stays.
        #expect(usage.entries["kept"]?.count == 3)
    }

    @Test func priorityBreaksTies() {
        let candidates = [
            PaletteCandidate(id: "a", title: "Design review"),
            PaletteCandidate(id: "b", title: "Design sync", priority: 1),
        ]
        let ranked = PaletteRanking.rank(candidates, query: "design", usage: PaletteUsage(), now: UTC.date("2026-10-28 10:00"))
        #expect(ranked.map(\.index) == [1, 0])
    }
}
