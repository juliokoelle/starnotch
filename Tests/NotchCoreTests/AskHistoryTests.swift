import Foundation
import Testing
@testable import NotchCore

struct AskHistoryTests {
    private func history() -> AskHistory {
        AskHistory(file: FileManager.default.temporaryDirectory.appending(path: "ask-\(UUID().uuidString)/ask-chats.json"))
    }

    private func turn(_ question: String) -> AskChat.Turn {
        AskChat.Turn(question: question, answer: AskAnswer(question: question, text: "Answer to \(question)", sources: [
            AskSource(id: "0", kind: .meeting, title: "Kickoff", quote: "30 Euro", speaker: "Jonas", date: "2026-10-12"),
        ], brain: "claude-code"))
    }

    @Test func keepsChatsNewestFirstWithTheirSources() throws {
        let history = history()
        var first = AskChat(started: Date(timeIntervalSince1970: 1_000), turns: [turn("Price?")])
        history.save(first)
        let second = AskChat(turns: [turn("Who owns the checklist?")])
        history.save(second)
        // A follow-up in the first chat moves it back to the top.
        first.turns.append(turn("And the discount?"))
        let chats = history.save(first)
        #expect(chats.map(\.id) == [first.id, second.id])
        let loaded = history.load()
        #expect(loaded == chats)
        #expect(loaded[0].turns[1].answer.sources.first?.speaker == "Jonas")
        #expect(loaded[0].title == "Price?")
        let mode = try FileManager.default.attributesOfItem(atPath: history.file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func emptyChatsAreNotKeptAndOneCanBeDeleted() {
        let history = history()
        history.save(AskChat())
        #expect(history.load().isEmpty)
        let chat = AskChat(turns: [turn("Price?")])
        history.save(chat)
        #expect(history.delete(chat.id).isEmpty)
        #expect(history.load().isEmpty)
    }
}
