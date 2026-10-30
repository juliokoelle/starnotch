import Foundation
import Testing
import TestSupport
@testable import NotchCore

@Suite struct TaraAskTests {
    private func parse(_ json: String) -> AskReply? { AskReply.parse(Bytes.data(json)) }

    @Test func answerWithEveryKindOfSource() throws {
        let json = #"{"type":"answer","question":"Was steht an?","text":"Investor-Call um 15 Uhr.","brain":"claude-code","reply_to":"ask-3","sources":[{"kind":"meeting","title":"Kickoff","quote":"Wir entscheiden 30 Euro.","speaker":"Jonas","meeting":"Kickoff","meeting_id":"2026-10-12-kickoff","date":"2026-10-12"},{"kind":"capture","id":"c1","title":"Lisa fragen","quote":"Lisa fragen","date":"2026-10-24"},{"kind":"note","id":"vault:0","title":"2026-10-28","quote":"","source":"vault","date":"","url":"file:///tmp/Daily.md"}]}"#
        guard case .answer(let answer, let replyTo) = try #require(parse(json)) else { Issue.record("not an answer"); return }
        #expect(replyTo == "ask-3")
        #expect(answer.brain == "claude-code" && !answer.onRules)
        #expect(answer.text == "Investor-Call um 15 Uhr.")
        #expect(answer.sources.map(\.kind) == [.meeting, .capture, .note])
        #expect(answer.sources[0].speaker == "Jonas" && answer.sources[0].date == "2026-10-12")
        #expect(answer.sources[1].title == "Lisa fragen" && answer.sources[1].url == nil)
        #expect(answer.sources[2].date == nil && answer.sources[2].url == Bytes.url("file:///tmp/Daily.md"))
        #expect(Set(answer.sources.map(\.id)).count == 3)
    }

    @Test func olderAnswersWithoutKindAreMeetings() throws {
        let json = #"{"type":"answer","question":"Preis?","text":"30 Euro.","sources":[{"quote":"30 Euro.","meeting":"Weekly","meeting_id":"w","date":"2026-10-19"}],"reply_to":2}"#
        guard case .answer(let answer, let replyTo) = try #require(parse(json)) else { Issue.record("not an answer"); return }
        #expect(replyTo == "2")
        #expect(answer.onRules)
        #expect(answer.sources == [AskSource(id: "0-w", kind: .meeting, title: "Weekly", quote: "30 Euro.", date: "2026-10-19")])
    }

    @Test func readyErrorsAndOffline() {
        #expect(parse(#"{"type":"ready","meetings":2,"brain":"claude-code","model":"sonnet"}"#) == .ready(brain: "claude-code"))
        #expect(parse(#"{"type":"error","message":"ask: empty question","reply_to":"ask-1"}"#) == .failed("ask: empty question", replyTo: "ask-1"))
        #expect(parse(#"{"type":"status","state":"offline","message":"Claude Code isn't signed in"}"#) == .offline("Claude Code isn't signed in"))
        #expect(parse(#"{"type":"status","state":"reloaded","meetings":3}"#) == nil)
        #expect(parse(#"{"type":"contradiction","now":"x"}"#) == nil)
        #expect(parse("not json") == nil)
    }

    @Test func commandCarriesTheConversation() {
        #expect(AskCommand.text("Preis?", id: "ask-1") == #"{"cmd":"ask","id":"ask-1","question":"Preis?"}"#)
        var conversation = AskConversation()
        conversation.append(question: "Preis?", answer: "30 Euro.")
        #expect(AskCommand.text("Wer?", conversation: conversation, image: "/tmp/w.png", id: "ask-2")
            == #"{"cmd":"ask","history":[{"answer":"30 Euro.","question":"Preis?"}],"id":"ask-2","image":"/tmp/w.png","question":"Wer?"}"#)
    }

    @Test func commandCarriesADroppedDocument() {
        #expect(AskCommand.text("Worum geht es?", document: AskDocument(name: "Angebot.pdf", text: "Preis 30 Euro"), id: "ask-4")
            == #"{"cmd":"ask","document":{"name":"Angebot.pdf","text":"Preis 30 Euro"},"id":"ask-4","question":"Worum geht es?"}"#)
    }

    @Test func commandCarriesScreenContextAndScreenSourcesParse() throws {
        let now = UTC.date("2026-10-29 15:00")
        let item = ScreenAskItem(id: "screen:0", app: "Mail", time: UTC.date("2026-10-29 14:05"), title: "Pricing", text: "deck v3")
        let line = AskCommand.text("Deck?", screen: [item], now: now, id: "ask-3")
        let object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let screen = try #require(object["screen"] as? [[String: Any]])
        #expect(screen.first?["app"] as? String == "Mail" && screen.first?["text"] as? String == "deck v3")
        #expect((screen.first?["label"] as? String)?.hasPrefix("Screen · Mail · ") == true)
        // No screen context: no field at all.
        #expect(!AskCommand.text("Deck?", id: "ask-4").contains("screen"))
        let reply = #"{"type":"answer","question":"Deck?","text":"v3","brain":"api","sources":[{"kind":"screen","id":"screen:0","title":"Screen · Mail · 14:05","quote":"deck v3","date":"2026-10-29"}]}"#
        guard case .answer(let answer, _) = AskReply.parse(Data(reply.utf8)) else { Issue.record("no answer"); return }
        #expect(answer.sources.first?.kind == .screen)
        #expect(answer.sources.first?.title == "Screen · Mail · 14:05")
    }

    @Test func conversationKeepsTheLastTurns() {
        var conversation = AskConversation()
        for n in 0..<9 { conversation.append(question: "q\(n)", answer: "a\(n)") }
        #expect(conversation.turns.count == AskConversation.limit)
        #expect(conversation.turns.first?.question == "q3" && conversation.turns.last?.answer == "a8")
        conversation.clear()
        #expect(conversation.turns.isEmpty)
    }

    @Test func hotKeyTapOpensAndCloses() {
        let start = UTC.date("2026-10-28 10:00")
        var gesture = AskHotKeyGesture()
        #expect(gesture.press(at: start, isOpen: false) == .open)
        #expect(gesture.release(at: start.addingTimeInterval(0.1)) == .nothing)
        #expect(gesture.press(at: start.addingTimeInterval(1), isOpen: true) == .wait)
        #expect(gesture.release(at: start.addingTimeInterval(1.1)) == .close)
    }

    @Test func hotKeyHoldListensThenSends() {
        let start = UTC.date("2026-10-28 10:00")
        var gesture = AskHotKeyGesture()
        #expect(gesture.press(at: start, isOpen: true) == .wait)
        // `holdElapsed` is mutating, so its results are taken before #expect sees them.
        let early = gesture.holdElapsed(at: start.addingTimeInterval(0.2))
        let held = gesture.holdElapsed(at: start.addingTimeInterval(0.4))
        let again = gesture.holdElapsed(at: start.addingTimeInterval(0.5))
        #expect(!early)
        #expect(held)
        #expect(!again)  // once per press
        #expect(gesture.listening)
        #expect(gesture.release(at: start.addingTimeInterval(2)) == .send)
        #expect(!gesture.listening)
        #expect(gesture.release(at: start.addingTimeInterval(3)) == .nothing)  // no press, no action
    }

    @Test func appleModelStatusFromTheHelper() {
        func status(_ json: String) -> AppleModelStatus { AppleModelStatus(statusLine: Bytes.data(json)) }
        #expect(status(#"{"available":true}"#) == .ready)
        #expect(status(#"{"available":false,"reason":"appleIntelligenceNotEnabled","message":"off"}"#) == .notEnabled)
        #expect(status(#"{"available":false,"reason":"modelNotReady","message":"downloading"}"#) == .downloading)
        #expect(status(#"{"available":false,"reason":"deviceNotEligible","message":"macOS 26"}"#) == .notSupported)
        #expect(status("") == .unknown)
        #expect(status(#"{"available":false,"reason":"somethingNew"}"#) == .unavailable)
        #expect(status(#"{"available":false}"#) == .unavailable)
        #expect(status(#"{"available":false,"reason":"noHelper"}"#) == .unknown)
    }

    @Test func answerSavedAsANote() {
        let answer = AskAnswer(question: "Preis?", text: "30 Euro im Monat.\n\nJonas hat es bestätigt.\n", sources: [
            AskSource(id: "0", kind: .meeting, title: "Kickoff", quote: "30 Euro.", date: "2026-10-12"),
            AskSource(id: "1", kind: .note, title: "Pricing"),
        ], brain: "claude-code")
        #expect(answer.note(asked: "Was haben wir\nbeim Preis entschieden?", sourcesLabel: "Quellen")
            == "# Was haben wir beim Preis entschieden?\n\n30 Euro im Monat.\n\nJonas hat es bestätigt.\n\nQuellen: Kickoff (2026-10-12), Pricing\n")
        // Without the asked text, the answer's own question is the title; no sources, no sources line.
        #expect(AskAnswer(question: "Preis?", text: "30 Euro.").note() == "# Preis?\n\n30 Euro.\n")
        #expect(AskAnswer(question: "", text: "30 Euro.").note() == "30 Euro.\n")
    }

    @Test func answerSavedToTheInboxKeepsQuestionAnswerAndSourcesApart() {
        let answer = AskAnswer(question: "Preis?", text: "30 Euro im Monat.\n\nJonas hat es bestätigt.\n", sources: [
            AskSource(id: "0", kind: .meeting, title: "Kickoff", quote: "30 Euro.", date: "2026-10-12"),
            AskSource(id: "1", kind: .note, title: "Pricing"),
        ], brain: "claude-code")
        #expect(answer.inboxLine(asked: "Was haben wir\nbeim Preis entschieden?", sourcesLabel: "Quellen")
            == "Was haben wir beim Preis entschieden? → 30 Euro im Monat. Jonas hat es bestätigt. (Quellen: Kickoff (2026-10-12), Pricing)")
        #expect(AskAnswer(question: "Preis?", text: "30 Euro.").inboxLine() == "Preis? → 30 Euro.")
        #expect(AskAnswer(question: "", text: "30 Euro.").inboxLine() == "30 Euro.")
    }

    @Test func threadKeepsAnsweredAndFailedTurnsInOrder() {
        var thread = AskThread()
        let answer = AskAnswer(question: "Preis?", text: "30 Euro.", sources: [AskSource(id: "0", kind: .meeting, title: "Kickoff")])
        thread.archive(question: nil, answer: nil, failure: nil)           // nothing asked yet
        thread.archive(question: "Preis?", answer: nil, failure: nil)      // still thinking: not kept
        #expect(thread.turns.isEmpty)
        thread.archive(question: "Preis?", answer: answer, failure: nil)
        // Failed after an earlier answer: the old answer isn't this question's.
        thread.archive(question: "Und der Rabatt?", answer: answer, failure: "Tara took too long")
        #expect(thread.turns.map(\.question) == ["Preis?", "Und der Rabatt?"])
        #expect(thread.turns[0].answer?.sources.count == 1 && thread.turns[0].failure == nil)
        #expect(thread.turns[1].answer == nil && thread.turns[1].failure == "Tara took too long")
        #expect(Set(thread.turns.map(\.id)).count == 2)
        thread.clear()
        #expect(thread.turns.isEmpty)
        thread.archive(question: "Wer?", answer: answer, failure: nil)
        #expect(thread.turns.first?.id == 2)  // ids stay unique after a clear
    }
}
