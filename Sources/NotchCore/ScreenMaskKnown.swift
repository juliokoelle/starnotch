import CryptoKit
import Foundation

// Screen context: the keys this Mac already holds, so the mask catches them whatever their shape.
// The app collects them (its own key file and Keychain items, keys exported in the shell's startup
// files) and hands them over once; only salted hashes are kept, with a new salt for every set.
// Never the values, never on disk, never in a log.

/// Keys and tokens the user already has, as salted hashes: `ScreenMask` masks a token on screen
/// whose hash is in the set.
public struct KnownSecrets: Sendable {
    /// Random bytes hashed in front of every value, new for every set (so new at every launch).
    private let salt: Data
    let hashes: Set<Data>
    /// The values' lengths (UTF-16), so only a token of a known length is hashed.
    private let lengths: Set<Int>

    public init() { self.init([String]()) }

    /// Learns the values worth learning (`worthLearning`) and forgets them at once: only their
    /// hashes stay.
    public init<Values: Sequence>(_ values: Values) where Values.Element == String {
        let salt = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let kept = Set(values.filter(Self.worthLearning))
        self.salt = salt
        hashes = Set(kept.map { Self.hash($0, salt: salt) })
        lengths = Set(kept.map { ($0 as NSString).length })
    }

    public var isEmpty: Bool { hashes.isEmpty }
    public var count: Int { hashes.count }

    /// Whether the token is one of the values.
    public func contains(_ token: String) -> Bool {
        lengths.contains((token as NSString).length) && hashes.contains(Self.hash(token, salt: salt))
    }

    /// Where the values stand in a text. A value is found as a whole word, or inside one between
    /// marks like `=`, `:`, quotes and brackets (`KEY="…"`, `(…)`), or before a full stop or comma.
    func ranges(in text: NSString) -> [NSRange] {
        guard let shortest = lengths.min() else { return [] }
        var found: [NSRange] = []
        for word in Self.wordPattern.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
            let range = word.range
            guard range.length >= shortest else { continue }
            var starts = [range.location]
            var ends = [range.location + range.length]
            for index in range.location..<(range.location + range.length) {
                let unit = text.character(at: index)
                if Self.marks.contains(unit) {
                    starts.append(index + 1)
                    ends.append(index)
                } else if unit == 0x2E {  // a full stop ends a sentence, it doesn't start a key
                    ends.append(index)
                }
            }
            ends.sort(by: >)
            var last = range.location
            // The longest value at each start; values found don't overlap.
            for start in starts where start >= last {
                for end in ends where end > start && lengths.contains(end - start) {
                    let candidate = NSRange(location: start, length: end - start)
                    if hashes.contains(Self.hash(text.substring(with: candidate), salt: salt)) {
                        found.append(candidate)
                        last = end
                        break
                    }
                }
            }
        }
        return found
    }

    private static let wordPattern = try! NSRegularExpression(pattern: #"\S+"#)
    private static let marks = Set("=:\"'`()[]{}<>,;!?@/".utf16)

    private static func hash(_ value: String, salt: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: salt)
        hasher.update(data: Data(value.utf8))
        return Data(hasher.finalize())
    }

    // MARK: The set in use

    /// What the mask uses when it isn't handed a set: empty until the app has learnt the keys,
    /// empty again when screen context stops.
    public static var current: KnownSecrets {
        get { lock.withLock { shared } }
        set { lock.withLock { shared = newValue } }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var shared = KnownSecrets()

    // MARK: Collecting

    /// A value worth learning: 8 or more characters in one piece, not a shell expression (`$(…)`,
    /// `$NAME`, backticks) and not a path. A shorter value would mask ordinary words.
    public static func worthLearning(_ value: String) -> Bool {
        value.count >= 8 && !value.contains(where: \.isWhitespace) && !value.contains("$") && !value.contains("`")
            && !["/", "~", "."].contains(where: value.hasPrefix)
    }

    /// The values of `export NAME=value` lines whose name ends in _KEY, _TOKEN, _SECRET or _PASSWORD,
    /// from a shell startup file (~/.zshrc). Read as text, never run: a value that needs the shell
    /// (`$(…)`, `$NAME`) is left out by `worthLearning`.
    public static func shellExports(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { part in
            let line = String(part)
            guard let match = exportPattern.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else { return nil }
            return (1...3).lazy.map { match.range(at: $0) }.first { $0.location != NSNotFound && $0.length > 0 }.map { (line as NSString).substring(with: $0) }
        }
    }

    private static let exportPattern = try! NSRegularExpression(
        pattern: #"^\s*export\s+[A-Za-z_][A-Za-z0-9_]*_(?:KEY|TOKEN|SECRET|PASSWORD)=(?:"([^"]*)"|'([^']*)'|([^\s#;"']+))"#,
        options: [.caseInsensitive])

    /// What a stored item holds: every string inside it when it is JSON (an OAuth token's access and
    /// refresh tokens), else the text itself.
    public static func values(stored: String) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(stored.utf8)) else { return [stored] }
        var found: [String] = []
        func walk(_ value: Any) {
            if let text = value as? String {
                found.append(text)
            } else if let list = value as? [Any] {
                list.forEach(walk)
            } else if let object = value as? [String: Any] {
                object.values.forEach(walk)
            }
        }
        walk(object)
        return found.isEmpty ? [stored] : found
    }
}
