/// Follows a speaker through a script: where they are, from what the recognizer heard.
///
/// Each update aligns the last words heard with the script around the current place, as a local
/// alignment: a misheard, extra or skipped word costs a little instead of breaking the match.
/// The place moves only on enough evidence: the next word or two on any match, further only on
/// runs of matching words, back only on a long run (the speaker started a passage again). Ad-libs
/// and noise match nothing nearby, so the place stays. When the latest words match nothing nearby
/// at all, the rest of the script is searched for a long run (a skipped paragraph).
public struct PrompterFollower: Sendable {
    public struct Tuning: Sendable {
        /// Words heard that are aligned each time: the end of the transcript.
        public var tail = 10
        /// Script words looked at ahead of and behind the place.
        public var ahead = 90
        public var behind = 40
        /// How far a skipped passage is looked for when nothing nearby matches.
        public var farAhead = 1500

        public init() {}
    }

    public let keys: [String]
    /// The keys read so far, so the index of the next key the speaker should say.
    public private(set) var position: Int
    private let stopwords: Set<String>
    private let tuning: Tuning
    private var lastHeard: [String] = []
    /// The recognizer's running transcript as last heard: its session and length. A jump by hand
    /// marks that text stale, so words said before it can't pull the place back to where they matched.
    private var session = 0
    private var transcriptBytes = 0
    private var stale: (session: Int, bytes: Int)?

    public init(keys: [String], language: PrompterLanguage, position: Int = 0, tuning: Tuning = Tuning()) {
        self.keys = keys
        self.stopwords = language.stopwords
        self.tuning = tuning
        self.position = min(max(0, position), keys.count)
    }

    public var isFinished: Bool { position >= keys.count }

    /// Moved by hand (arrow keys, scrolling): following goes on from here, with what is said next.
    public mutating func jump(to position: Int) {
        self.position = min(max(0, position), keys.count)
        lastHeard = []
        stale = (session, transcriptBytes)
    }

    /// The recognizer's transcript so far in this `session` (a new recognition starts a new one);
    /// only its end is read. True when the place moved.
    @discardableResult
    public mutating func hear(_ transcript: String, session: Int = 0) -> Bool {
        self.session = session
        transcriptBytes = transcript.utf8.count
        var text = Substring(transcript)
        if let stale, stale.session == session, stale.bytes > 0 {
            guard transcriptBytes > stale.bytes else { return false }
            // What came after the jump, from the first whole word.
            text = Substring(String(decoding: transcript.utf8.dropFirst(stale.bytes), as: UTF8.self)).drop { !$0.isWhitespace }
        }
        if text.utf8.count > 320 {
            text = text.suffix(240).drop { !$0.isWhitespace }
        }
        return hear(keys: PrompterWords.keys(text))
    }

    /// Match keys heard, oldest first.
    @discardableResult
    public mutating func hear(keys heard: [String]) -> Bool {
        let heard = Array(heard.suffix(tuning.tail))
        guard !heard.isEmpty, heard != lastHeard, !keys.isEmpty else { return false }
        lastHeard = heard
        let high = min(keys.count, position + tuning.ahead)
        let near = align(heard, from: max(0, position - tuning.behind), to: high)
        if let move = pick(near, heard: heard.count) {
            position = move
            return true
        }
        // The latest word matched nothing near the place: maybe a passage was skipped.
        let latestNear = near.contains { $0.heardEnd == heard.count && $0.end + 3 >= position }
        guard !latestNear, heard.count >= 4, high < keys.count else { return false }
        let far = align(heard, from: high, to: min(keys.count, high + tuning.farAhead))
            .filter { $0.heardEnd >= heard.count - 1 && $0.run >= 4 && $0.fresh >= 4 }
        guard let found = far.max(by: { ($0.score, -$0.end) < ($1.score, -$1.end) }) else { return false }
        position = found.end + 1
        return true
    }

    // MARK: Alignment

    struct Candidate {
        /// The script key of the last match, and the heard word (1-based) it matched.
        var end: Int
        var heardEnd: Int
        var score: Double
        /// Evidence from matches at or after the place (new ground), and from all matches.
        var fresh: Double
        var all: Double
        /// Matches in a row at the end.
        var run: Int
    }

    private struct Cell {
        var score = 0.0
        var fresh = 0.0
        var all = 0.0
        var run = 0
        var matched = false
    }

    /// Smith–Waterman over the heard words and `keys[low..<high]`, also matching two heard words
    /// to one script word and back ("kunden feedback" / "kundenfeedback", "email" / "e mail").
    /// Every alignment that ends on a match with one of the last three heard words is a candidate.
    func align(_ heard: [String], from low: Int, to high: Int) -> [Candidate] {
        let n = heard.count
        let m = high - low
        guard n > 0, m > 0 else { return [] }
        let heardPairs = heard.indices.map { $0 == 0 ? "" : heard[$0 - 1] + heard[$0] }
        let scriptPairs = (0..<m).map { $0 == 0 ? "" : keys[low + $0 - 1] + keys[low + $0] }
        var rows = [[Cell]](repeating: [Cell](repeating: Cell(), count: m + 1), count: 3)
        var candidates: [Candidate] = []
        for i in 1...n {
            let current = i % 3, previous = (i + 2) % 3, before = (i + 1) % 3
            rows[current][0] = Cell()
            let word = heard[i - 1]
            for j in 1...m {
                let index = low + j - 1
                var best = Cell()
                func consider(_ cell: Cell) {
                    if cell.score > best.score || (cell.score == best.score && cell.matched && !best.matched) { best = cell }
                }
                func extend(_ from: Cell, by weight: (score: Double, evidence: Double)) -> Cell {
                    Cell(score: from.score + weight.score, fresh: from.fresh + (index >= position ? weight.evidence : 0),
                         all: from.all + weight.evidence, run: from.run + 1, matched: true)
                }
                func gap(_ from: Cell) -> Cell {
                    Cell(score: from.score - 1, fresh: from.fresh, all: from.all, run: 0, matched: false)
                }
                let diagonal = rows[previous][j - 1]
                if let weight = weight(word, keys[index]) {
                    consider(extend(diagonal, by: weight))
                } else {
                    consider(gap(diagonal))
                }
                if i >= 2, heardPairs[i - 1] == keys[index] {
                    consider(extend(rows[before][j - 1], by: compound(keys[index])))
                }
                if j >= 2, scriptPairs[j - 1] == word {
                    consider(extend(rows[previous][j - 2], by: compound(word)))
                }
                consider(gap(rows[previous][j]))   // a word heard that isn't in the script
                consider(gap(rows[current][j - 1])) // a script word not said (or not heard)
                rows[current][j] = best
                if best.matched, best.score > 0, i >= n - 2 {
                    candidates.append(Candidate(end: index, heardEnd: i, score: best.score, fresh: best.fresh,
                                                all: best.all, run: best.run))
                }
            }
        }
        return candidates
    }

    /// Where to move, if anywhere. Forward wins over back; back needs a long run with the latest word.
    private func pick(_ candidates: [Candidate], heard: Int) -> Int? {
        var forward: (rank: Double, end: Int)?
        var back: (score: Double, end: Int)?
        for candidate in candidates {
            let distance = candidate.end + 1 - position
            if distance > 0 {
                guard passes(distance, candidate) else { continue }
                let rank = candidate.score - 0.05 * Double(distance) + (candidate.heardEnd == heard ? 1 : 0)
                if rank > forward?.rank ?? -.infinity { forward = (rank, candidate.end) }
            } else if distance < 0, candidate.heardEnd == heard, candidate.run >= 4, candidate.all >= 4 {
                if candidate.score > back?.score ?? -.infinity { back = (candidate.score, candidate.end) }
            }
        }
        if let forward { return forward.end + 1 }
        return back.map { $0.end + 1 }
    }

    /// Enough evidence to move `distance` keys ahead: the nearer, the less it takes.
    private func passes(_ distance: Int, _ candidate: Candidate) -> Bool {
        switch distance {
        case 1...2: candidate.fresh >= 0.35
        case 3...8: candidate.fresh >= 2 || (candidate.run >= 2 && candidate.fresh >= 1.35)
        case 9...25: candidate.run >= 2 && candidate.fresh >= 2
        default: candidate.run >= 3 && candidate.fresh >= 3
        }
    }

    /// A heard word against a script key: alignment score and evidence, nil when they differ.
    /// Common words count for less; a near miss (one letter in four) counts as half a match.
    private func weight(_ heard: String, _ script: String) -> (score: Double, evidence: Double)? {
        if heard == script { return stopwords.contains(script) ? (1, 0.35) : (2, 1) }
        return Self.similar(heard, script) ? (1.2, 0.6) : nil
    }

    private func compound(_ joined: String) -> (score: Double, evidence: Double) {
        stopwords.contains(joined) ? (1, 0.35) : (2, 1)
    }

    /// Spelled alike: at most one edit in four letters, words of four letters or more, no digits.
    static func similar(_ a: String, _ b: String) -> Bool {
        let a = Array(a.unicodeScalars), b = Array(b.unicodeScalars)
        guard a.count >= 4, b.count >= 4, abs(a.count - b.count) <= 2,
              !a.contains(where: { $0.properties.numericType != nil }),
              !b.contains(where: { $0.properties.numericType != nil }) else { return false }
        let limit = max(a.count, b.count) / 4
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var row = [i] + Array(repeating: 0, count: b.count)
            var smallest = i
            for j in 1...b.count {
                row[j] = min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                smallest = min(smallest, row[j])
            }
            if smallest > limit { return false }
            previous = row
        }
        return previous[b.count] <= limit
    }
}
