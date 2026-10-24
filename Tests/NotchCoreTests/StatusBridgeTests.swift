import Testing
import TestSupport
@testable import NotchCore

@Suite struct StatusBridgeTests {
    let now = UTC.date("2026-10-22 10:00")

    @Test func parsesTheStatusLineJSON() throws {
        let json = #"{"session_id":"abc","model":{"id":"claude-opus-5-5","display_name":"Opus"},"context_window":{"used_percentage":43.2,"context_window_size":200000},"rate_limits":{"five_hour":{"used_percentage":62,"resets_at":1792677240},"seven_day":{"used_percentage":48.5,"resets_at":"2026-10-27T08:00:00Z"}}}"#
        let snapshot = try #require(StatusSnapshot.parse(Bytes.data(json), capturedAt: now))
        #expect(snapshot.sessionID == "abc")
        #expect(snapshot.contextUsedPercentage == 43.2)
        #expect(snapshot.contextWindowSize == 200_000)
        #expect(snapshot.fiveHour?.usedPercentage == 62)
        #expect(UTC.seconds(snapshot.fiveHour?.resetsAt) == 1_792_677_240)
        #expect(UTC.string(snapshot.sevenDay?.resetsAt) == "2026-10-27 08:00")
        #expect(snapshot.model == "claude-opus-5-5")
    }

    @Test func missingParts() throws {
        // API-key users and fresh sessions have no rate_limits yet.
        let bare = try #require(StatusSnapshot.parse(Bytes.data(#"{"session_id":"x"}"#), capturedAt: now))
        #expect(bare.fiveHour == nil)
        #expect(bare.contextUsedPercentage == nil)
        #expect(StatusSnapshot.parse(Bytes.data(#"{"cwd":"/x"}"#), capturedAt: now) == nil)
        #expect(StatusSnapshot.parse(Bytes.data("not json"), capturedAt: now) == nil)
        let millis = try #require(StatusSnapshot.parse(Bytes.data(#"{"session_id":"m","rate_limits":{"five_hour":{"used_percentage":"5","resets_at":1792677240000}}}"#), capturedAt: now))
        #expect(UTC.seconds(millis.fiveHour?.resetsAt) == 1_792_677_240)
    }

    @Test func texts() {
        #expect(UsageText.left(until: UTC.date("2026-10-22 12:14"), now: now) == "2 h 14 m left")
        #expect(UsageText.left(until: UTC.date("2026-10-22 10:38"), now: now) == "38 m left")
        #expect(UsageText.left(until: UTC.date("2026-10-22 09:00"), now: now) == "resetting")
        #expect(UsageText.resetDay(UTC.date("2026-10-27 08:00"), now: now, calendar: UTC.calendar) == "resets Tue")
        #expect(UsageText.resetDay(UTC.date("2026-10-22 18:00"), now: now, calendar: UTC.calendar) == "resets today 18:00")
        #expect(UsageText.contextLevel(69) == QuotaEstimator.Level.calm)
        #expect(UsageText.contextLevel(70) == QuotaEstimator.Level.warn)
        #expect(UsageText.contextLevel(95) == QuotaEstimator.Level.critical)
    }

    @Test func contextTokensFromTranscript() {
        let line = #"{"type":"assistant","message":{"content":[],"usage":{"input_tokens":12,"cache_read_input_tokens":120000,"cache_creation_input_tokens":3000,"output_tokens":500}}}"#
        #expect(SessionLog.activity(fromTail: line).contextTokens == 123_012)
    }
}

@Suite struct UsageShortTests {
    @Test func dropsLeft() {
        #expect(UsageText.short("53 m left") == "53 m")
        #expect(UsageText.short("2 h 14 m left") == "2 h 14 m")
        #expect(UsageText.short("resetting") == "resetting")
    }
}
