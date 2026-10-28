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
        // 2026-10-22 through today: the call of 2026-10-20 is older.
        #expect(summary.week.calls == 4 && summary.week.byFeature["ask"] == 2)
    }

    @Test func callsAfterNowDoNotCount() {
        let summary = TaraUsage.summary(TaraUsage.parse(ledger), now: UTC.date("2026-10-28 08:00"), calendar: UTC.calendar)
        #expect(summary.today.calls == 1)
    }

    @Test func emptyLedger() {
        #expect(TaraUsage.summary([], now: UTC.date("2026-10-28 08:00")) == TaraUsage.Summary())
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
    }
}
