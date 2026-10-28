import AppKit
import Foundation
import NotchCore

/// Where quick captures go.
///
/// With an `InboxSink` connector, the connector files the capture (and keeps its own copy when
/// it can't deliver). Without one, every capture is appended to `capture-queue.jsonl` (0600) in
/// the app's support folder, and, when `[capture] markdown_file` is set in config.toml, to that
/// file as a Markdown task or note line.
@MainActor
final class CaptureInbox {
    typealias Outcome = CaptureOutcome

    nonisolated static var queueFile: URL { Brand.supportFolder.appending(path: "capture-queue.jsonl") }

    private(set) var people: [Person] = []
    /// Tara's privacy switches (set by the app).
    var privacy: () -> MemoryPrivacy = { MemoryPrivacy() }

    /// Known people for the parser, from the `PeopleProvider` connector if there is one.
    func loadPeople(from provider: (any PeopleProvider)? = Runtime.people) {
        guard let provider else { return }
        Task.detached(priority: .utility) {
            let people = provider.people()
            await MainActor.run { self.people = people }
        }
    }

    /// Files one capture. Never throws: the queue is the safety net.
    func file(text: String, route: QuickCapture.Route, parse: CaptureParse, now: Date = Date()) async -> Outcome {
        let capture = Capture(text: text, route: route.capture, due: parse.dueField(calendar: .current),
                              people: parse.people, created: now)
        if let sink = Runtime.inbox {
            return await sink.file(capture)
        }
        var outcome = Outcome.queued(reason: "no inbox connected")
        if let file = Runtime.captureMarkdownFile, Self.appendMarkdown(capture, to: file) {
            outcome = .delivered
        }
        // Paused, or captures switched off: Tara doesn't keep it. Only when the Markdown inbox
        // didn't take it does the queue keep it anyway, marked as not Tara's, so it isn't lost.
        let remembers = privacy().records(.captures, at: now)
        guard remembers || outcome != .delivered else { return outcome }
        var record: [String: Any] = [
            "id": UUID().uuidString,
            "created": ISO8601DateFormatter().string(from: now),
            "route": capture.route.rawValue,
            "text": text,
            "due": capture.due as Any,
            "people": capture.people.map(\.slug),
            "delivered": outcome == .delivered,
        ]
        if !remembers { record["memory"] = false }
        Self.append(record)
        return outcome
    }

    /// The Markdown file captures land in, when no connector takes them.
    nonisolated static var markdownFile: URL? { Runtime.inbox == nil ? Runtime.captureMarkdownFile : nil }

    /// Opens the Markdown inbox in its default app, creating it first so the click always lands
    /// somewhere. An inbox in the notes vault opens there (in Obsidian for an Obsidian vault), and
    /// a missing one opens the vault instead of being created in it.
    static func openMarkdown(_ file: URL) {
        let fm = FileManager.default
        if let vault = Runtime.vault, vault.isConfigured, let folder = vault.folder,
           file.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/") {
            NSWorkspace.shared.open(vault.link(to: fm.fileExists(atPath: file.path) ? file : folder))
            return
        }
        if !fm.fileExists(atPath: file.path) {
            try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: file.path, contents: Data("# Inbox\n\n".utf8))
        }
        NSWorkspace.shared.open(file)
    }

    /// `- [ ] text (due 2026-10-23)` for tasks and questions, `- 14:32 text` for notes.
    nonisolated static func markdownLine(_ capture: Capture) -> String {
        let flat = capture.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        switch capture.route {
        case .task: return "- [ ] \(flat)" + (capture.due.map { " (due \($0))" } ?? "")
        case .question: return "- [ ] \(flat)"
        case .note: return "- \(TimeText.clock(capture.created)) \(flat)"
        }
    }

    nonisolated static func appendMarkdown(_ capture: Capture, to file: URL) -> Bool {
        let fm = FileManager.default
        if !fm.fileExists(atPath: file.path) {
            try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard fm.createFile(atPath: file.path, contents: nil) else { return false }
        }
        guard let handle = try? FileHandle(forWritingTo: file) else { return false }
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            var line = markdownLine(capture) + "\n"
            if end > 0 {
                // Start on a new line if the file doesn't end with one.
                try handle.seek(toOffset: end - 1)
                if try handle.read(upToCount: 1) != Data("\n".utf8) { line = "\n" + line }
                try handle.seekToEnd()
            }
            try handle.write(contentsOf: Data(line.utf8))
            return true
        } catch {
            return false
        }
    }

    nonisolated static func append(_ record: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        let fm = FileManager.default
        _ = APIToken.ensureFolder()
        if !fm.fileExists(atPath: queueFile.path) {
            fm.createFile(atPath: queueFile.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: queueFile) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data + Data("\n".utf8))
    }
}

extension QuickCapture.Route {
    var capture: Capture.Route {
        switch self {
        case .task: .task
        case .question: .question
        case .note: .note
        }
    }
}
