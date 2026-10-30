import Foundation
import Testing
@testable import NotchCore

struct MarkdownInboxTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "md-inbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func appendsToAFileThatAlreadyHasLines() throws {
        let file = try folder().appending(path: "Inbox.md")
        #expect(MarkdownInbox.append("- [ ] one", to: file))
        // The second append failed before 30.10.: the handle couldn't read the last byte.
        #expect(MarkdownInbox.append("- [ ] two", to: file))
        #expect(try String(contentsOf: file, encoding: .utf8) == "- [ ] one\n- [ ] two\n")
    }

    @Test func startsOnANewLineWhenTheFileDoesNotEndWithOne() throws {
        let file = try folder().appending(path: "Inbox.md")
        try "# Inbox".write(to: file, atomically: true, encoding: .utf8)
        #expect(MarkdownInbox.append("- 14:32 idea", to: file))
        #expect(try String(contentsOf: file, encoding: .utf8) == "# Inbox\n- 14:32 idea\n")
    }

    @Test func prepareWritesAReadmeAndCarriesTheOldInboxOver() throws {
        let root = try folder()
        let legacy = root.appending(path: "old/Inbox.md")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "- [ ] from before\n".write(to: legacy, atomically: true, encoding: .utf8)
        let file = root.appending(path: "Starnotch/Inbox.md")

        MarkdownInbox.prepare(file, legacy: legacy)

        #expect(try String(contentsOf: file, encoding: .utf8) == "- [ ] from before\n")
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "Starnotch/README.md").path))
        #expect(FileManager.default.fileExists(atPath: legacy.path))  // copied, not moved
        // Once the inbox exists, prepare leaves it alone.
        try "- [ ] new\n".write(to: file, atomically: true, encoding: .utf8)
        MarkdownInbox.prepare(file, legacy: legacy)
        #expect(try String(contentsOf: file, encoding: .utf8) == "- [ ] new\n")
    }
}

struct RememberedDocumentsTests {
    @Test func aDocumentBecomesANoteAndAgainReplacesIt() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "remember-\(UUID().uuidString)")
        let folder = root.appending(path: "Documents")
        let source = URL(fileURLWithPath: "/Users/someone/Downloads/Angebot Ada.pdf")
        let file = try #require(RememberedDocuments.save(name: "Angebot Ada.pdf", source: source, text: "\nRabatt 10 %\n", in: folder))
        #expect(file.lastPathComponent == "Angebot Ada.md")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.hasPrefix("# Angebot Ada.pdf\n\nHanded to Tara on "))
        #expect(text.contains("`/Users/someone/Downloads/Angebot Ada.pdf`") && text.hasSuffix("Rabatt 10 %\n"))
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "README.md").path))
        RememberedDocuments.save(name: "Angebot Ada.pdf", source: source, text: "Rabatt 15 %", in: folder)
        #expect(try String(contentsOf: file, encoding: .utf8).hasSuffix("Rabatt 15 %\n"))
    }
}
