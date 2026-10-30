import Foundation
import Testing
import TestSupport
@testable import NotchCore

@Suite struct TaraUsageTests {
    /// Lines as agent/usage.py writes them (the numbers of a real cold and warm Claude Code call).
    private let ledger = """
    {"time": "2026-10-20T09:00:00Z", "feature": "ask", "brain": "claude-code", "model": "claude-sonnet-5-5", "input_tokens": 2, "cache_creation_input_tokens": 32499, "cache_read_input_tokens": 577, "output_tokens": 274, "duration_ms": 5121, "cost_usd": 0.1327977}
    {"time": "2026-10-23T08:00:00Z", "feature": "ask", "brain": "claude-code", "model": "claude-sonnet-5-5", "input_tokens": 2, "cache_creation_input_tokens": 32499, "cache_read_input_tokens": 577, "output_tokens": 274, "duration_ms": 5121, "cost_usd": 0.1327977}
    {"time": "2026-10-28T07:59:00Z", "feature": "meeting", "brain": "claude-code", "model": "claude-sonnet-5-5", "input_tokens": 2, "cache_creation_input_tokens": 1239, "cache_read_input_tokens": 32358, "output_tokens": 223, "duration_ms": 2737, "cost_usd": 0.0104258}
    not json
    {"feature": "ask"}
    {"time": "2026-10-28T08:30:00Z", "feature": "capture", "brain": "api", "model": "claude-some-future-model", "input_tokens": 100, "output_tokens": 10, "duration_ms": 900, "cost_usd": null}
    {"time": "2026-10-28T08:31:00Z", "feature": "ask", "brain": "claude-code", "model": "claude-sonnet-5-5", "input_tokens": 2, "cache_creation_input_tokens": 1115, "cache_read_input_tokens": 32025, "output_tokens": 308, "duration_ms": 4456, "cost_usd": 0.0107465}
    """

    @Test func parsesWhatTheSidecarWrites() {
        let calls = TaraUsage.parse(ledger)
        #expect(calls.count == 5)  // the line that isn't JSON and the one without a time are skipped
        #expect(calls[0].tokens == 2 + 32499 + 577 + 274)
        #expect(calls[0].costUSD == 0.1327977 && calls[0].model == "claude-sonnet-5-5")
        #expect(calls[3].costUSD == nil && calls[3].cacheReadTokens == 0 && calls[3].brain == "api")
    }

    @Test func todayAndTheLastSevenDays() {
        let summary = TaraUsage.summary(TaraUsage.parse(ledger), now: UTC.date("2026-10-28 09:00"), calendar: UTC.calendar)
        #expect(summary.today.calls == 3)
        #expect(summary.today.byFeature == ["meeting": 1, "capture": 1, "ask": 1])
        #expect(summary.today.cachedTokens == 32358 + 32025)
        #expect(abs(summary.today.costUSD - (0.0104258 + 0.0107465)) < 1e-9)  // the unpriced call adds nothing
        #expect(summary.today.unpricedCalls == 1 && TaraUsage.cost(summary.today) == "$0.02+")
        #expect(summary.week.unpricedCalls == 1)
        // 2026-10-22 through today: the call of 2026-10-20 is older.
        #expect(summary.week.calls == 4 && summary.week.byFeature["ask"] == 2)
    }

    @Test func linesBeforeSinceAreSkippedUnparsed() {
        let calls = TaraUsage.parse(ledger, since: UTC.date("2026-10-23 08:00"))
        #expect(calls.map(\.time) == [UTC.date("2026-10-23 08:00"), UTC.date("2026-10-28 07:59"),
                                      UTC.date("2026-10-28 08:30"), UTC.date("2026-10-28 08:31")])
        // A line in another shape is parsed in full and left to the summary.
        #expect(TaraUsage.parse(#"{"feature": "ask", "time": "2026-10-01T00:00:00Z"}"#, since: UTC.date("2026-10-23 08:00")).count == 1)
    }

    @Test func sidecarArgument() {
        let folder = URL(fileURLWithPath: "/tmp/It's here")
        #expect(TaraUsage.argument(folder: folder) == #" --usage '/tmp/It'\''s here/usage.jsonl'"#)
    }

    @Test func callsAfterNowDoNotCount() {
        let summary = TaraUsage.summary(TaraUsage.parse(ledger), now: UTC.date("2026-10-28 08:00"), calendar: UTC.calendar)
        #expect(summary.today.calls == 1)
    }

    @Test func emptyLedger() {
        #expect(TaraUsage.summary([], now: UTC.date("2026-10-28 08:00")) == TaraUsage.Summary())
    }

    @Test func breakdownByFeatureBrainAndDay() {
        let usage = TaraUsage.breakdown(TaraUsage.parse(ledger), days: 7, now: UTC.date("2026-10-28 09:00"), calendar: UTC.calendar)
        #expect(usage.total.calls == 4)  // 2026-10-22 through today
        #expect(usage.total.durationMs == 5121 + 2737 + 900 + 4456)
        #expect(usage.total.averageTokens == (33352 + 33822 + 110 + 33450) / 4)
        #expect(usage.byBrain["claude-code"]?.calls == 3 && usage.byBrain["api"]?.unpricedCalls == 1)
        #expect(usage.byFeature["ask"]?.tokens == 33352 + 33450 && usage.byFeature["meeting"]?.calls == 1)
        #expect(usage.days.count == 7 && usage.days.first?.start == UTC.date("2026-10-22 00:00"))
        #expect(usage.days[1].tokens == 33352 && usage.days[2].tokens == 0)
        #expect(usage.days[6].tokensByBrain == ["claude-code": 33822 + 33450, "api": 110])
        let today = TaraUsage.breakdown(TaraUsage.parse(ledger), days: 1, now: UTC.date("2026-10-28 09:00"), calendar: UTC.calendar)
        #expect(today.total.calls == 3 && today.days.count == 1)
        #expect(abs(today.byBrain["claude-code"]!.averageSeconds - (2.737 + 4.456) / 2) < 1e-9)
    }

    @Test func breakdownDaysAcrossDaylightSaving() {
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        // 00:30 on 25 October in Berlin, the night the clocks go back.
        let line = #"{"time": "2026-10-24T22:30:00Z", "feature": "digest", "brain": "codex", "model": "gpt", "input_tokens": 500, "output_tokens": 20, "duration_ms": 900, "cost_usd": null}"#
        let usage = TaraUsage.breakdown(TaraUsage.parse(line), days: 7, now: UTC.date("2026-10-28 09:00"), calendar: berlin)
        #expect(usage.days.map(\.tokens) == [0, 0, 0, 520, 0, 0, 0])
        #expect(usage.byBrain["codex"]?.unpricedCalls == 1)
    }

    @Test func emptyBreakdownStillHasItsDays() {
        let usage = TaraUsage.breakdown([], days: 30, now: UTC.date("2026-10-28 09:00"), calendar: UTC.calendar)
        #expect(usage.days.count == 30 && usage.total == TaraUsage.Totals() && usage.total.averageSeconds == 0)
    }

    @Test func compactNumbers() {
        #expect(TaraUsage.compact(950) == "950")
        #expect(TaraUsage.compact(12_000) == "12k")
        #expect(TaraUsage.compact(33_078) == "33.1k")
        #expect(TaraUsage.compact(410_400) == "410k")
        #expect(TaraUsage.compact(999_700) == "1M")
        #expect(TaraUsage.compact(1_234_567) == "1.2M")
        #expect(TaraUsage.dollars(0) == "$0")
        #expect(TaraUsage.dollars(0.004) == "< $0.01")
        #expect(TaraUsage.dollars(0.1327977) == "$0.13")
        #expect(TaraUsage.dollars(12.4) == "$12.40")
        let german = Locale(identifier: "de_DE")
        #expect(TaraUsage.compact(33_078, locale: german) == "33,1k" && TaraUsage.compact(12_000, locale: german) == "12k")
        #expect(TaraUsage.dollars(12.4, locale: german) == "$12,40" && TaraUsage.dollars(0.004, locale: german) == "< $0,01")
        var none = TaraUsage.Totals()
        #expect(TaraUsage.cost(none) == "$0")
        none.unpricedCalls = 1
        #expect(TaraUsage.cost(none) == "$0+")
    }
}
