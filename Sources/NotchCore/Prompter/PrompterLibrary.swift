import CoreGraphics
import Foundation

/// A script for the teleprompter, as kept in the recent list.
public struct PrompterScript: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var text: String
    public var added: Date
    /// Last read; the list is newest first by it.
    public var used: Date
    /// The word reading stopped at last time, to pick up there.
    public var word: Int
    /// The language picked by hand in the band; nil follows the text (`spokenLanguage`).
    public var language: PrompterLanguage?

    /// Longer texts are cut here: an hour of speech is about 9,000 words.
    public static let maxLength = 200_000

    public init(text: String, title: String? = nil, now: Date = Date(), id: String = UUID().uuidString) {
        self.id = id
        self.text = String(text.prefix(Self.maxLength))
        let given = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.title = given.isEmpty ? Self.title(of: text) : given
        self.added = now
        self.used = now
        self.word = 0
    }

    /// The language to listen in: the one picked, else the text's.
    public var spokenLanguage: PrompterLanguage { language ?? PrompterLanguage.detect(text) }

    public var wordCount: Int { text.split(whereSeparator: \.isWhitespace).count }

    /// The first line with words, without Markdown marks, at most 60 characters.
    public static func title(of text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#>*-_ \t[]")) }
            .first { $0.contains(where: \.isLetter) } ?? ""
        let words = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return words.count > 60 ? String(words.prefix(59)).trimmingCharacters(in: .whitespaces) + "…" : words
    }
}

/// The recent scripts, kept on this Mac only (`prompter-scripts.json` in the support folder,
/// readable by the user only), newest first, at most `limit`. The same text pasted again is the
/// same script, moved to the top with its place.
public struct PrompterLibrary: Sendable {
    public static let limit = 12
    public let file: URL

    public init(file: URL) {
        self.file = file
    }

    public func load() -> [PrompterScript] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([PrompterScript].self, from: data)) ?? []
    }

    /// Keeps `script` (replacing the one with its id) at the top.
    @discardableResult
    public func save(_ script: PrompterScript) -> [PrompterScript] {
        let scripts = Self.keeping(script, in: load())
        write(scripts)
        return scripts
    }

    @discardableResult
    public func delete(_ id: String) -> [PrompterScript] {
        let scripts = load().filter { $0.id != id }
        write(scripts)
        return scripts
    }

    /// `scripts` with `script` on top in place of the one with its id, newest first, cut to `limit`.
    public static func keeping(_ script: PrompterScript, in scripts: [PrompterScript]) -> [PrompterScript] {
        Array(([script] + scripts.filter { $0.id != script.id }).sorted { $0.used > $1.used }.prefix(limit))
    }

    /// The script for `text`: the one already kept with the same text (its place and language
    /// kept), or a new one.
    public static func script(for text: String, title: String? = nil, in scripts: [PrompterScript], now: Date = Date()) -> PrompterScript {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if var known = scripts.first(where: { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed }) {
            known.used = now
            if let title, !title.isEmpty { known.title = title }
            return known
        }
        return PrompterScript(text: trimmed, title: title, now: now)
    }

    private func write(_ scripts: [PrompterScript]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(scripts) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? data.write(to: file, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

/// How the teleprompter reads: following the voice or at a constant speed, and the band's type
/// size and height. Saved with the app's other settings.
public struct PrompterSettings: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable {
        /// The text follows the speaker (on-device speech recognition).
        case voice
        /// The text moves at `wordsPerMinute`, for when listening isn't possible or wanted.
        case constant
    }

    public var mode: Mode
    public var textSize: Double
    /// Lines in the band.
    public var lines: Int
    public var wordsPerMinute: Int

    public static let textSizes: ClosedRange<Double> = 18...36
    public static let lineCounts: ClosedRange<Int> = 3...5
    public static let speeds: ClosedRange<Int> = 60...220

    public init(mode: Mode = .voice, textSize: Double = 26, lines: Int = 4, wordsPerMinute: Int = 130) {
        self.mode = mode
        self.textSize = min(max(textSize, Self.textSizes.lowerBound), Self.textSizes.upperBound)
        self.lines = min(max(lines, Self.lineCounts.lowerBound), Self.lineCounts.upperBound)
        self.wordsPerMinute = min(max(wordsPerMinute, Self.speeds.lowerBound), Self.speeds.upperBound)
    }

    /// Two points larger (positive) or smaller, within `textSizes`.
    public mutating func stepTextSize(_ direction: Int) {
        self = PrompterSettings(mode: mode, textSize: textSize + 2 * Double(direction), lines: lines, wordsPerMinute: wordsPerMinute)
    }

    /// One line more or less, within `lineCounts`.
    public mutating func stepLines(_ direction: Int) {
        self = PrompterSettings(mode: mode, textSize: textSize, lines: lines + direction, wordsPerMinute: wordsPerMinute)
    }

    /// Ten words a minute faster or slower, within `speeds`.
    public mutating func stepSpeed(_ direction: Int) {
        self = PrompterSettings(mode: mode, textSize: textSize, lines: lines, wordsPerMinute: wordsPerMinute + 10 * direction)
    }

    // Tolerant decoding: a missing or odd value falls back to its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PrompterSettings()
        self.init(mode: (try? c.decodeIfPresent(Mode.self, forKey: .mode)) ?? defaults.mode,
                  textSize: (try? c.decodeIfPresent(Double.self, forKey: .textSize)) ?? defaults.textSize,
                  lines: (try? c.decodeIfPresent(Int.self, forKey: .lines)) ?? defaults.lines,
                  wordsPerMinute: (try? c.decodeIfPresent(Int.self, forKey: .wordsPerMinute)) ?? defaults.wordsPerMinute)
    }
}

/// The script broken into lines for the band: words in order, a line full when the next word
/// wouldn't fit, a new line at each paragraph with a little extra room above it.
public struct PrompterLayout: Equatable, Sendable {
    public struct Line: Equatable, Sendable {
        public var words: Range<Int>
        /// Distance from the top of the first line.
        public var top: CGFloat
    }

    public let lines: [Line]
    public let lineHeight: CGFloat

    /// - Parameters:
    ///   - widths: each word's width in the band's font.
    ///   - paragraphs: which words start a paragraph.
    public init(widths: [CGFloat], paragraphs: [Bool], space: CGFloat, width: CGFloat, lineHeight: CGFloat, paragraphGap: CGFloat) {
        self.lineHeight = lineHeight
        var lines: [Line] = []
        var start = 0
        var x: CGFloat = 0
        var top: CGFloat = 0
        func startsParagraph(_ index: Int) -> Bool { index < paragraphs.count && paragraphs[index] }
        func close(at end: Int) {
            guard end > start else { return }
            if !lines.isEmpty {
                top += lineHeight + (startsParagraph(start) ? paragraphGap : 0)
            }
            lines.append(Line(words: start..<end, top: top))
            start = end
        }
        for (index, wordWidth) in widths.enumerated() {
            let breaks = index > start && (startsParagraph(index) || x + space + wordWidth > width)
            if breaks { close(at: index) }
            x = index == start ? wordWidth : x + space + wordWidth
        }
        close(at: widths.count)
        self.lines = lines
    }

    /// The bottom of the last line.
    public var height: CGFloat { (lines.last?.top ?? 0) + (lines.isEmpty ? 0 : lineHeight) }

    /// The line holding `word`; the last line for the end of the script.
    public func line(ofWord word: Int) -> Int {
        guard !lines.isEmpty else { return 0 }
        var low = 0
        var high = lines.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lines[mid].words.lowerBound <= word { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// The last line whose top is at or above `y`.
    public func line(atY y: CGFloat) -> Int {
        guard !lines.isEmpty else { return 0 }
        var low = 0
        var high = lines.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lines[mid].top <= y + 0.5 { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// Points per second for `wordsPerMinute`, from the words per line on average, so constant
    /// speed reads at about that pace.
    public func pointsPerSecond(wordsPerMinute: Int) -> CGFloat {
        guard let last = lines.last, !lines.isEmpty else { return 0 }
        let perLine = CGFloat(last.words.upperBound) / CGFloat(lines.count)
        let gaps = height / CGFloat(lines.count)  // a line's share of the height, paragraph gaps included
        return CGFloat(wordsPerMinute) / 60 / max(1, perLine) * gaps
    }
}
