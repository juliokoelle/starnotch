import Foundation

/// Fuzzy matching for the command palette: the query's characters in order, anywhere in the
/// text, scored so that word starts, runs of consecutive characters and an early first match
/// win. Case and accents are ignored; each word of the query matches on its own, in any order.
public enum FuzzyMatch {
    /// The score (roughly 0 to 1.3, higher is better) and the matched character offsets in
    /// `text`, or `nil` when some word of the query doesn't occur in it. An empty query matches
    /// everything with score 0.
    public static func match(_ query: String, in text: String) -> (score: Double, positions: [Int])? {
        let words = query.split(whereSeparator: \.isWhitespace).map(fold)
        guard !words.isEmpty else { return (0, []) }
        let original = Array(text)
        let haystack = original.map { fold(String($0)).first ?? $0 }
        var total = 0.0
        var positions = Set<Int>()
        for word in words {
            guard let found = best(Array(word), in: haystack, original: original) else { return nil }
            total += found.score
            positions.formUnion(found.positions)
        }
        let length = words.reduce(0) { $0 + $1.count }
        var score = total / (Double(length) * perCharacter)
        let folded = String(haystack)
        let whole = fold(query.trimmingCharacters(in: .whitespaces))
        if folded == whole { score += 0.3 } else if folded.hasPrefix(whole) { score += 0.2 }
        return (score, positions.sorted())
    }

    /// What a perfect character earns (word start at the very beginning, in a run).
    static let perCharacter = 4.0

    static func fold(_ string: some StringProtocol) -> String {
        String(string).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// The best alignment of one query word: tried from every place its first character occurs,
    /// then greedily forward, preferring word starts.
    private static func best(_ word: [Character], in text: [Character], original: [Character]) -> (score: Double, positions: [Int])? {
        guard let first = word.first, word.count <= text.count else { return nil }
        var result: (score: Double, positions: [Int])?
        for start in text.indices where text[start] == first {
            guard let found = align(word, in: text, original: original, from: start) else { continue }
            if found.score > (result?.score ?? -.infinity) { result = found }
        }
        return result
    }

    private static func align(_ word: [Character], in text: [Character], original: [Character], from start: Int) -> (score: Double, positions: [Int])? {
        var positions = [start]
        var index = start + 1
        for character in word.dropFirst() {
            // The next occurrence, but a word start a little further on beats a mid-word hit.
            guard let next = text[index...].firstIndex(of: character) else { return nil }
            var pick = next
            if next != positions.last! + 1, !isWordStart(next, original),
               let start = text[next...].indices.first(where: { text[$0] == character && isWordStart($0, original) }) {
                pick = start
            }
            positions.append(pick)
            index = pick + 1
        }
        var score = 0.0
        for (n, position) in positions.enumerated() {
            score += 1
            if position == 0 { score += 2 } else if isWordStart(position, original) { score += 1.5 }
            if n > 0 {
                let gap = position - positions[n - 1] - 1
                if gap == 0 { score += 1 } else { score -= min(1.5, 0.15 * Double(gap)) }
            }
        }
        // A match that starts late counts a little less.
        score -= min(1, 0.04 * Double(start))
        return (score, positions)
    }

    /// The first character, after a separator, or an upper-case letter after a lower-case one.
    static func isWordStart(_ index: Int, _ text: [Character]) -> Bool {
        guard index > 0 else { return true }
        let previous = text[index - 1]
        if previous.isWhitespace || "-_./:·›(".contains(previous) { return true }
        return previous.isLowercase && text[index].isUppercase
    }
}

/// One thing the palette can offer, as far as ranking is concerned.
public struct PaletteCandidate: Equatable, Sendable {
    public var id: String
    public var title: String
    /// Other words it answers to ("preferences" for Settings); they match, but aren't highlighted.
    public var keywords: [String]
    /// The provider's own sense of what matters now, 0 to 1 (a session waiting, the next meeting).
    public var priority: Double

    public init(id: String, title: String, keywords: [String] = [], priority: Double = 0) {
        self.id = id
        self.title = title
        self.keywords = keywords
        self.priority = priority
    }
}

/// How often and how recently each palette item was picked: what you use comes first.
public struct PaletteUsage: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var count: Int
        public var last: Date
    }

    public private(set) var entries: [String: Entry] = [:]
    /// Kept small: the least useful entries go first.
    public static let limit = 300
    /// A pick counts half after this long.
    public static let halfLife: TimeInterval = 7 * 86_400

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    public mutating func record(_ id: String, at now: Date) {
        var entry = entries[id] ?? Entry(count: 0, last: now)
        entry.count += 1
        entry.last = now
        entries[id] = entry
        if entries.count > Self.limit {
            let weakest = entries.keys.sorted { boost($0, now: now) < boost($1, now: now) }
            for id in weakest.prefix(entries.count - Self.limit) { entries[id] = nil }
        }
    }

    /// 0 for something never picked, up to 0.6 for something picked often and lately.
    public func boost(_ id: String, now: Date) -> Double {
        guard let entry = entries[id] else { return 0 }
        let age = max(0, now.timeIntervalSince(entry.last))
        let recency = pow(0.5, age / Self.halfLife)
        return min(0.6, 0.18 * log2(1 + Double(entry.count))) * recency
    }
}

/// A candidate that made it into the list.
public struct PaletteMatch: Equatable, Sendable {
    /// Position in the candidates handed to `PaletteRanking.rank`.
    public var index: Int
    public var score: Double
    /// Matched character offsets in the title, for highlighting.
    public var highlights: [Int]
}

/// Orders the palette: the fuzzy match first, then usage and the provider's priority. Without a
/// query, what was used lately and often leads, then the providers' own order.
public enum PaletteRanking {
    public static func rank(_ candidates: [PaletteCandidate], query: String, usage: PaletteUsage,
                            now: Date, limit: Int = 60) -> [PaletteMatch] {
        let empty = query.trimmingCharacters(in: .whitespaces).isEmpty
        var matches: [PaletteMatch] = []
        for (index, candidate) in candidates.enumerated() {
            let extra = usage.boost(candidate.id, now: now) + 0.2 * min(1, max(0, candidate.priority))
            if empty {
                matches.append(PaletteMatch(index: index, score: extra, highlights: []))
                continue
            }
            if let hit = FuzzyMatch.match(query, in: candidate.title) {
                matches.append(PaletteMatch(index: index, score: hit.score + extra, highlights: hit.positions))
            } else if let hit = candidate.keywords.compactMap({ FuzzyMatch.match(query, in: $0) }).max(by: { $0.score < $1.score }) {
                matches.append(PaletteMatch(index: index, score: 0.8 * hit.score + extra, highlights: []))
            }
        }
        // Stable: equal scores keep the providers' order.
        matches.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
        return Array(matches.prefix(limit))
    }
}
