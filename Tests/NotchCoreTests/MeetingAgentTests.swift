import Testing
import TestSupport
@testable import NotchCore

@Suite struct MeetingAgentTests {
    private func parse(_ json: String) -> MeetingLine? { MeetingLine.parse(Bytes.data(json)) }

    @Test func contradictionCarriesBothQuotes() throws {
        let json = #"{"type":"contradiction","now":"Wir waren doch bei 25 Euro im Monat, oder?","speaker":"Max","t":24.0,"before":{"quote":"Das Lumen-Abo kostet 30 Euro im Monat.","speaker":"Jonas","meeting":"Kickoff Lumen-Abo","meeting_id":"2026-10-12-kickoff","date":"2026-10-12"},"note":"Im Kickoff wurden 30 Euro entschieden."}"#
        guard case .card(let card) = try #require(parse(json)) else { Issue.record("not a card"); return }
        #expect(card.kind == .contradiction)
        #expect(card.detail == "Im Kickoff wurden 30 Euro entschieden.")
        #expect(card.blocks == [
            .text("Im Kickoff wurden 30 Euro entschieden."),
            .heading("Just said"),
            .quote("Wir waren doch bei 25 Euro im Monat, oder?", source: "Max"),
            .heading("Earlier"),
            .quote("Das Lumen-Abo kostet 30 Euro im Monat.", source: "Jonas · Kickoff Lumen-Abo · 2026-10-12"),
        ])
    }

    @Test func questionCommitmentAnswer() throws {
        let question = try #require(parse(#"{"type":"question","text":"Max, wie ist der Stand?","reason":"Offene Zusage"}"#))
        #expect(question == .card(MeetingCard(kind: .question, title: "Ask", detail: "Max, wie ist der Stand?",
                                              blocks: [.text("Max, wie ist der Stand?"), .quote("Offene Zusage", source: "")])))

        let commitment = try #require(parse(#"{"type":"commitment","who":"Lisa","what":"Folien schicken","due":"2026-10-28","quote":"Ich schicke die Folien."}"#))
        #expect(commitment == .card(MeetingCard(kind: .commitment, title: "Commitment", detail: "Lisa: Folien schicken (by 2026-10-28)",
                                                blocks: [.text("Lisa: Folien schicken (by 2026-10-28)"),
                                                         .quote("Ich schicke die Folien.", source: "Lisa")])))

        let empty = try #require(parse(#"{"type":"answer","question":"Preis?","text":"Weiß ich nicht.","sources":[]}"#))
        guard case .card(let answer) = empty else { Issue.record("not a card"); return }
        #expect(answer.blocks.last == .quote("Nothing in the memory for this.", source: ""))
    }

    @Test func prepListsEverything() throws {
        let json = #"{"type":"prep","participants":["Max","Lisa"],"meetings":[],"last_meeting":{"meeting":"Weekly","date":"2026-10-19","summary":"Preis bestätigt."},"decisions":[{"text":"Preis bleibt bei 30 Euro","quote":"Wir bleiben bei 30 Euro.","speaker":"Jonas","meeting":"Weekly","date":"2026-10-19"}],"open_commitments":[{"who":"Max","what":"Margenzahlen schicken","due":"2026-10-16","overdue":true,"quote":"Ich schicke die Zahlen.","meeting":"Kickoff","date":"2026-10-12"}],"captures":[{"route":"task","text":"Max anstupsen","due":null,"overdue":false}]}"#
        guard case .card(let card) = try #require(parse(json)) else { Issue.record("not a card"); return }
        #expect(card.detail == "Max, Lisa")
        #expect(card.blocks == [
            .heading("Last time"), .text("Weekly · 2026-10-19"), .quote("Preis bestätigt.", source: ""),
            .heading("Decisions"), .text("Preis bleibt bei 30 Euro"), .quote("Wir bleiben bei 30 Euro.", source: "Jonas · Weekly · 2026-10-19"),
            .heading("Open commitments"), .text("Max: Margenzahlen schicken (overdue since 2026-10-16)"),
            .quote("Ich schicke die Zahlen.", source: "Kickoff · 2026-10-12"),
            .heading("Your notes"), .text("Max anstupsen"),
        ])
    }

    @Test func otherLines() {
        #expect(parse(#"{"type":"ready","meetings":2,"memory":"/x","model":null,"errors":[]}"#) == .ready(meetings: 2, model: nil))
        #expect(parse(#"{"type":"utterance","speaker":"","text":" Hallo ","t":1}"#) == .utterance(speaker: "", text: "Hallo"))
        #expect(parse(#"{"type":"status","state":"saved","meeting_id":"x","path":"/p"}"#) == .status(state: "saved", message: nil))
        #expect(parse(#"{"type":"error","message":"kaputt"}"#) == .error("kaputt"))
        #expect(parse(#"{"type":"partial","text":"Hal"}"#) == nil)
        #expect(parse("Welcome to zsh") == nil)
        #expect(parse(#"{"type":"question"}"#) == nil)
    }

    @Test func jamieSyncLines() {
        #expect(parse(#"{"type":"status","state":"login","url":"https://jamie/auth"}"#) == .status(state: "login", message: "https://jamie/auth"))
        #expect(parse(#"{"type":"synced","meeting_id":"jamie-abc","title":"Weekly","date":"2026-10-19","lines":120,"path":"/p"}"#) == .synced(title: "Weekly"))
        #expect(parse(#"{"type":"status","state":"synced","meetings":12}"#) == .syncDone(meetings: 12))
        #expect(parse(#"{"type":"status","state":"warning","message":"get_meeting abc: 404"}"#) == .status(state: "warning", message: "get_meeting abc: 404"))
    }

    @Test func commandsRoundTrip() {
        #expect(MeetingCommand.save(title: "Weekly") == Bytes.data(#"{"cmd":"save","title":"Weekly"}"# + "\n"))
        #expect(MeetingCommand.reload == Bytes.data(#"{"cmd":"reload"}"# + "\n"))
        #expect(MeetingCommand.prep(participants: ["Max"]) == Bytes.data(#"{"cmd":"prep","participants":["Max"]}"# + "\n"))
    }
}
