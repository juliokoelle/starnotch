import Foundation

/// The Markdown file quick capture appends to, one line per capture, and the visible Starnotch
/// folder it lives in by default (`~/Documents/Starnotch`), where people, notes apps and any AI
/// can read it. Context from apps, meetings and the screen stays apart, in the app's own folder.
public enum MarkdownInbox {
    /// `~/Documents/Starnotch/Inbox.md`.
    public static var defaultFile: URL { Brand.documentsFolder.appending(path: "Inbox.md") }

    /// Appends `line` on a line of its own, creating the file and its folder when needed.
    public static func append(_ line: String, to file: URL) -> Bool {
        let fm = FileManager.default
        if !fm.fileExists(atPath: file.path) {
            try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard fm.createFile(atPath: file.path, contents: nil) else { return false }
        }
        // For updating: the last byte is read to see whether the file ends with a newline. A
        // handle opened for writing only can't read, so every append to a file with content
        // failed (since 24.10., found 30.10.).
        guard let handle = try? FileHandle(forUpdating: file) else { return false }
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            var text = line + "\n"
            if end > 0 {
                try handle.seek(toOffset: end - 1)
                if try handle.read(upToCount: 1) != Data("\n".utf8) { text = "\n" + text }
                try handle.seekToEnd()
            }
            try handle.write(contentsOf: Data(text.utf8))
            return true
        } catch {
            return false
        }
    }

    /// Before the first capture into `file`: a README beside it that says what the folder holds,
    /// and the lines of an inbox kept elsewhere before (`legacy`) carried over. Copied: the old
    /// file stays where it is. Does nothing once `file` exists.
    public static func prepare(_ file: URL, legacy: URL?) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: file.path) else { return }
        let folder = file.deletingLastPathComponent()
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        writeReadme(in: folder)
        if let legacy, legacy.standardizedFileURL != file.standardizedFileURL,
           let old = try? Data(contentsOf: legacy), !old.isEmpty {
            try? old.write(to: file)
        }
    }

    /// The README that says what the Starnotch folder holds, unless one is there already.
    public static func writeReadme(in folder: URL) {
        let readme = folder.appending(path: "README.md")
        guard !FileManager.default.fileExists(atPath: readme.path) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data(readmeText.utf8).write(to: readme)
    }

    static let readmeText = """
    # Starnotch

    What you jot down with Starnotch, as plain Markdown, so you, your notes app and any AI tool can read it.

    - `Inbox.md`: tasks, questions and notes from quick capture (⌃⌥N), the newest at the bottom. Tasks are checkboxes (`- [ ]`).
    - `Documents/`: the text of documents you handed Tara to remember, one Markdown file each. The originals stay where they were.

    What Starnotch gathers from apps, meetings and the screen stays apart, in its own folder on this Mac.

    """
}

/// Documents handed to Tara to remember: a Markdown copy of their text in the Starnotch folder's
/// `Documents`, which Tara searches with every question. The original file is only read.
public enum RememberedDocuments {
    /// `~/Documents/Starnotch/Documents`.
    public static var folder: URL { Brand.documentsFolder.appending(path: "Documents") }

    /// The note: the name as its title, where it came from and when, then the text.
    public static func markdown(name: String, source: URL, text: String, date: Date) -> String {
        let day = ISO8601DateFormatter.string(from: date, timeZone: .current, formatOptions: [.withFullDate])
        return "# \(name)\n\nHanded to Tara on \(day) from `\(source.path)`.\n\n\(text.trimmingCharacters(in: .whitespacesAndNewlines))\n"
    }

    /// Writes the note as `<name>.md` in `folder` (the same name again replaces it, so a newer
    /// version wins) and returns it; nil when it can't be written.
    @discardableResult
    public static func save(name: String, source: URL, text: String, date: Date = Date(), in folder: URL = folder) -> URL? {
        let stem = (name as NSString).deletingPathExtension
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let file = folder.appending(path: (stem.isEmpty ? "Document" : stem) + ".md")
        MarkdownInbox.writeReadme(in: folder.deletingLastPathComponent())
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(markdown(name: name, source: source, text: text, date: date).utf8).write(to: file, options: .atomic)
            return file
        } catch {
            return nil
        }
    }
}
