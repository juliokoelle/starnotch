import AppKit
import NotchCore
import PDFKit
import UniformTypeIdentifiers

/// A file dropped on Tara in the notch: read for its text, never moved or changed.
enum TaraDocument {
    /// Larger files aren't read (a scanned book, a video with the wrong ending).
    static let maxBytes = 50_000_000
    private static let attributed: Set<String> = ["doc", "docx", "odt", "rtf", "rtfd", "wordml"]
    private static let plain: Set<String> = ["md", "markdown", "txt", "csv", "tsv", "json", "yaml", "yml", "toml", "log", "html", "htm", "xml"]

    static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    /// The text of a PDF, a Word, RTF or OpenDocument file, or a plain text, Markdown or code file;
    /// nil for anything else, an empty one or one too large. Runs off the main thread.
    nonisolated static func text(of url: URL) -> String? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxBytes else { return nil }
        let ext = url.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        let text: String?
        if type?.conforms(to: .pdf) == true {
            text = PDFDocument(url: url)?.string
        } else if attributed.contains(ext) {
            text = (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
        } else if plain.contains(ext) || type?.conforms(to: .text) == true || type?.conforms(to: .sourceCode) == true {
            text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1))
        } else {
            text = nil
        }
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
