import Foundation

/// The two languages the teleprompter listens in. The script's language picks the recognizer;
/// the band has a switch for when the guess is wrong.
public enum PrompterLanguage: String, Codable, CaseIterable, Sendable {
    case en, de

    /// German or English, by which language's everyday words the text uses more (umlauts and ß
    /// count for German). A text with neither goes to `fallback`.
    public static func detect(_ text: String, fallback: PrompterLanguage = .en) -> PrompterLanguage {
        var german = 0
        var english = 0
        for word in text.lowercased().split(whereSeparator: { !$0.isLetter }).prefix(5000) {
            let word = String(word)
            if germanMarkers.contains(word) { german += 1 }
            if englishMarkers.contains(word) { english += 1 }
            if word.contains(where: { "äöüß".contains($0) }) { german += 1 }
        }
        if german == english { return fallback }
        return german > english ? .de : .en
    }

    // Words that are common in one language and rare in the other ("in", "so", "was" and "an" are
    // both, so they say nothing).
    private static let germanMarkers: Set<String> = [
        "der", "die", "das", "und", "ist", "nicht", "ich", "wir", "sie", "es", "ein", "eine", "mit", "auf", "für",
        "von", "zu", "den", "dem", "des", "auch", "sich", "wie", "aber", "oder", "wenn", "dass", "noch", "nur",
        "schon", "sind", "haben", "wird", "werden", "bei", "nach", "aus", "uns", "unsere", "kann", "mehr", "heute",
    ]
    private static let englishMarkers: Set<String> = [
        "the", "and", "is", "are", "not", "we", "you", "it", "with", "on", "for", "of", "to", "that", "this",
        "but", "or", "if", "be", "have", "has", "can", "our", "they", "what", "from", "at", "as", "just",
        "more", "about", "today", "there", "their", "which",
    ]

    /// Words that occur everywhere and say little about where in a script the speaker is, as
    /// match keys (folded: "für" is "fur").
    public var stopwords: Set<String> {
        switch self {
        case .en: Self.englishStopwords
        case .de: Self.germanStopwords
        }
    }

    private static let englishStopwords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "of", "to", "in", "on", "at", "for", "with", "from", "by", "as",
        "is", "are", "was", "were", "be", "been", "it", "its", "this", "that", "these", "those", "we", "you",
        "i", "he", "she", "they", "our", "your", "my", "me", "us", "them", "so", "if", "then", "than", "there",
        "here", "not", "no", "do", "does", "did", "have", "has", "had", "will", "would", "can", "could", "just",
        "also", "very", "all", "what", "which", "who", "how", "um", "uh", "oh", "okay", "yeah",
    ]
    private static let germanStopwords: Set<String> = [
        "der", "die", "das", "den", "dem", "des", "ein", "eine", "einen", "einem", "einer", "eines", "und", "oder",
        "aber", "doch", "zu", "im", "in", "an", "am", "auf", "aus", "bei", "mit", "nach", "von", "vom", "zum",
        "zur", "fur", "uber", "ist", "sind", "war", "waren", "sein", "es", "er", "sie", "wir", "ich", "du", "ihr",
        "uns", "euch", "mein", "unser", "unsere", "nicht", "kein", "keine", "auch", "so", "dann", "als", "wie",
        "wenn", "dass", "ja", "nein", "noch", "schon", "nur", "sehr", "hat", "haben", "hatte", "wird", "werden",
        "kann", "da", "hier", "mal", "also", "ah", "ahm", "ehm", "okay",
    ]
}

/// Match keys: what the script says and what the recognizer writes, made comparable. Lower case,
/// no accents, no punctuation, hyphenated words split ("state-of-the-art", "E-Mail"), digit groups
/// joined ("1,000", "10:30") and number words as digits ("twenty-five", "fünfundzwanzig" → "25"),
/// because the recognizer writes numbers either way.
public enum PrompterWords {
    /// The keys of `text`.
    public static func keys(_ text: some StringProtocol) -> [String] {
        keyed(text.split(whereSeparator: \.isWhitespace)).map(\.key)
    }

    /// The keys of a list of words, each with the index of the word it came from. A number spoken
    /// as several words becomes one key, on its first word.
    static func keyed(_ words: [some StringProtocol]) -> [(key: String, word: Int)] {
        var raw: [(key: String, word: Int)] = []
        for (index, word) in words.enumerated() {
            for part in parts(of: word) { raw.append((part, index)) }
        }
        return Numbers.merge(raw)
    }

    /// One word's keys: folded, split at anything that isn't a letter or a digit, except a dot,
    /// comma or colon between two digits, which joins them.
    static func parts(of word: some StringProtocol) -> [String] {
        let folded = fold(word)
        var parts: [String] = []
        var current = ""
        let characters = Array(folded)
        for (index, character) in characters.enumerated() {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if ".,:".contains(character), current.last?.isNumber == true,
                      index + 1 < characters.count, characters[index + 1].isNumber {
                continue
            } else {
                if !current.isEmpty { parts.append(current) }
                current = ""
                if character == "%" { parts.append("%") }
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts.map { $0 == "percent" || $0 == "prozent" ? "%" : $0 }
    }

    /// Lower case, without accents, ß as ss, apostrophes dropped ("don't" is "dont").
    static func fold(_ word: some StringProtocol) -> String {
        String(word)
            .replacingOccurrences(of: "ß", with: "ss")
            .replacingOccurrences(of: "ẞ", with: "ss")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .filter { !"'’‘`´".contains($0) }
    }

    /// Spoken numbers as digits, English and German.
    enum Numbers {
        enum Kind { case unit, teen, tens, hundred, scale, whole }

        /// The keys with each run of number words merged into its value ("two thousand twenty six"
        /// → "2026"). A word that can't continue the number starts a new one ("one two" is 1, 2).
        static func merge(_ raw: [(key: String, word: Int)]) -> [(key: String, word: Int)] {
            var result: [(key: String, word: Int)] = []
            var run = Run()
            var index = 0
            while index < raw.count {
                let (key, word) = raw[index]
                // "one hundred and five": "and" joins only between a hundred or a thousand and more.
                if key == "and", run.last == .hundred || run.last == .scale, index + 1 < raw.count,
                   let next = classify(raw[index + 1].key), [.unit, .teen, .tens].contains(next.kind) {
                    index += 1
                    continue
                }
                if let number = classify(key) {
                    if !run.accepts(number) {
                        if let value = run.value { result.append((String(value), run.word)) }
                        run = Run()
                    }
                    run.add(number, word: word)
                } else {
                    if let value = run.value { result.append((String(value), run.word)) }
                    run = Run()
                    result.append((key, word))
                }
                index += 1
            }
            if let value = run.value { result.append((String(value), run.word)) }
            return result
        }

        struct Number {
            var value: Int
            var kind: Kind
        }

        /// A number run being read: the thousands and millions so far, and the part below them.
        struct Run {
            var total = 0
            var current = 0
            var last: Kind?
            var word = 0
            /// The largest scale used, so "thousand thousand" doesn't count twice.
            var scale = Int.max

            var value: Int? { last == nil ? nil : total + current }

            func accepts(_ number: Number) -> Bool {
                guard let last else { return true }
                switch number.kind {
                case .unit: return [.tens, .hundred, .scale].contains(last) && (last != .tens || current % 10 == 0)
                case .teen, .tens: return last == .hundred || last == .scale
                case .hundred: return (last == .unit || last == .teen || last == .whole) && current > 0 && current < 100
                case .scale: return last != .scale && number.value < scale && total + current > 0
                case .whole: return false
                }
            }

            mutating func add(_ number: Number, word: Int) {
                if last == nil { self.word = word }
                switch number.kind {
                case .unit, .teen, .tens, .whole: current += number.value
                case .hundred: current = max(1, current) * 100
                case .scale:
                    total += max(1, current) * number.value
                    current = 0
                    scale = number.value
                }
                last = number.kind
            }
        }

        static func classify(_ key: String) -> Number? {
            if let scale = scales[key] { return Number(value: scale, kind: .scale) }
            if let value = english[key] {
                let kind: Kind = value == 100 ? .hundred : value >= 20 ? .tens : value >= 10 ? .teen : .unit
                return Number(value: value, kind: kind)
            }
            if key.allSatisfy(\.isASCIIDigit), key.count <= 15, let value = Int(key) { return Number(value: value, kind: .whole) }
            if let value = german(key) { return Number(value: value, kind: .whole) }
            return nil
        }

        static let scales: [String: Int] = [
            "thousand": 1_000, "million": 1_000_000, "millions": 1_000_000, "billion": 1_000_000_000,
            "tausend": 1_000, "millionen": 1_000_000, "milliarde": 1_000_000_000, "milliarden": 1_000_000_000,
        ]

        static let english: [String: Int] = [
            "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
            "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
            "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30,
            "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90, "hundred": 100,
        ]

        // German writes numbers below a million as one word: "zweitausendsechsundzwanzig". Folded
        // keys, so "fünf" is "funf" and "dreißig" is "dreissig".
        static let germanUnits: [String: Int] = [
            "ein": 1, "zwei": 2, "drei": 3, "vier": 4, "funf": 5, "sechs": 6, "sieben": 7, "acht": 8, "neun": 9,
        ]
        static let germanBelowHundred: [String: Int] = [
            "eins": 1, "zwei": 2, "drei": 3, "vier": 4, "funf": 5, "sechs": 6, "sieben": 7, "acht": 8, "neun": 9,
            "zehn": 10, "elf": 11, "zwolf": 12, "dreizehn": 13, "vierzehn": 14, "funfzehn": 15, "sechzehn": 16,
            "siebzehn": 17, "achtzehn": 18, "neunzehn": 19, "zwanzig": 20, "dreissig": 30, "vierzig": 40,
            "funfzig": 50, "sechzig": 60, "siebzig": 70, "achtzig": 80, "neunzig": 90,
        ]

        /// A German number word's value; nil for any other word, and for "ein"/"eine" on their
        /// own, which are articles.
        static func german(_ word: String) -> Int? {
            if word == "null" { return 0 }
            guard word != "ein", word != "eine" else { return nil }
            return belowMillion(Substring(word))
        }

        private static func belowMillion(_ word: Substring) -> Int? {
            guard let range = word.range(of: "tausend") else { return belowThousand(word) }
            let left = word[..<range.lowerBound]
            var right = word[range.upperBound...]
            if right.hasPrefix("und") { right = right.dropFirst(3) }
            guard let thousands = left.isEmpty ? 1 : belowThousand(left), thousands > 0,
                  let rest = right.isEmpty ? 0 : belowThousand(right) else { return nil }
            return thousands * 1000 + rest
        }

        private static func belowThousand(_ word: Substring) -> Int? {
            guard let range = word.range(of: "hundert") else { return belowHundred(word) }
            let left = word[..<range.lowerBound]
            var right = word[range.upperBound...]
            if right.hasPrefix("und") { right = right.dropFirst(3) }
            guard let hundreds = left.isEmpty ? 1 : germanUnits[String(left)],
                  let rest = right.isEmpty ? 0 : belowHundred(right) else { return nil }
            return hundreds * 100 + rest
        }

        private static func belowHundred(_ word: Substring) -> Int? {
            if let value = germanBelowHundred[String(word)] { return value }
            guard let range = word.range(of: "und"), let unit = germanUnits[String(word[..<range.lowerBound])],
                  let tens = germanBelowHundred[String(word[range.upperBound...])], tens >= 20, tens % 10 == 0 else { return nil }
            return unit + tens
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

/// A script split for reading: the words as written (shown in the band) and their match keys (to
/// follow the speaker). A blank line starts a paragraph; words in square brackets are stage
/// directions ("[slide 3]", "[pause]"), shown but never expected to be spoken.
public struct PrompterText: Equatable, Sendable {
    public struct Word: Equatable, Sendable {
        public var text: String
        /// The first word after a blank line.
        public var paragraph: Bool
        public var cue: Bool

        public init(text: String, paragraph: Bool = false, cue: Bool = false) {
            self.text = text
            self.paragraph = paragraph
            self.cue = cue
        }
    }

    public let words: [Word]
    public let keys: [String]
    /// The word each key comes from, never decreasing.
    public let keyWords: [Int]

    public init(_ script: String) {
        var words: [Word] = []
        var inCue = false
        let paragraphs = script.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n").split(whereSeparator: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
        for paragraph in paragraphs {
            let tokens = paragraph.joined(separator: " ").split(whereSeparator: \.isWhitespace)
            for (index, token) in tokens.enumerated() {
                if token.hasPrefix("[") { inCue = true }
                words.append(Word(text: String(token), paragraph: index == 0 && !words.isEmpty, cue: inCue))
                if token.contains("]") { inCue = false }
            }
            inCue = false  // a cue never runs past its paragraph
        }
        self.words = words
        // Keys only from spoken words; a cue in the middle of a number ends it.
        var keys: [String] = []
        var keyWords: [Int] = []
        var start = 0
        while start < words.count {
            guard !words[start].cue else { start += 1; continue }
            var end = start
            while end < words.count, !words[end].cue { end += 1 }
            for (key, word) in PrompterWords.keyed(words[start..<end].map(\.text)) {
                keys.append(key)
                keyWords.append(start + word)
            }
            start = end
        }
        self.keys = keys
        self.keyWords = keyWords
    }

    /// The word to read next once the keys before `position` are read; `words.count` at the end.
    public func word(atKey position: Int) -> Int {
        position < keyWords.count ? keyWords[max(0, position)] : words.count
    }

    /// The first key at or after `word`, so following picks up there (`keys.count` past the end).
    public func key(atWord word: Int) -> Int {
        var low = 0
        var high = keyWords.count
        while low < high {
            let mid = (low + high) / 2
            if keyWords[mid] < word { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// A Markdown file as plain script text: headings and list items become their own
    /// paragraphs, emphasis, code marks and link targets go, front matter and comments too.
    public static func plain(markdown: String) -> String {
        var text = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        if text.hasPrefix("---\n"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) {
            text = String(text[end.upperBound...])
        }
        text = text.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        var lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            var line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.range(of: "^([-*_]\\s*){3,}$", options: .regularExpression) != nil {
                lines.append("")
                continue
            }
            var block = false
            for pattern in ["^#{1,6}\\s+", "^>\\s?", "^[-*+]\\s+(\\[[ xX]\\]\\s+)?", "^\\d+[.)]\\s+"] {
                if let range = line.range(of: pattern, options: .regularExpression) {
                    line.removeSubrange(range)
                    block = true
                }
            }
            if block { lines.append("") }
            lines.append(line)
            if block { lines.append("") }
        }
        text = lines.joined(separator: "\n")
        let inline: [(String, String)] = [
            ("!\\[([^\\]]*)\\]\\([^)]*\\)", "$1"),       // images: their alt text
            ("\\[\\[([^\\]|]*\\|)?([^\\]]*)\\]\\]", "$2"), // [[Note]] and [[Note|shown]]
            ("\\[([^\\]]+)\\]\\([^)]*\\)", "$1"),         // links: their text
            ("(\\*\\*|__)(.+?)\\1", "$2"),
            ("(?<![\\w*])\\*(?!\\s)(.+?)(?<!\\s)\\*(?![\\w*])", "$1"),
            ("`+", ""),
        ]
        for (pattern, template) in inline {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
