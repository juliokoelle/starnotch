import Foundation

// Screen context: what is masked before anything is kept. Masked means replaced: the original
// characters are gone from the text that is stored, shown or sent, not just hidden in a view.
// Over-masking is preferred to a leak, so a label like "Password:" masks the word after it even
// when that word is harmless.
//
// The mask runs on a whole read at once (its texts joined by line breaks), before the text is
// split into lines and cut to length: a private key spread over many lines, or a label and its
// value in two separate texts ("Password" / "hunter2"), are masked like one line.

public enum ScreenMask {
    /// What a mask replaced; each kind has its own placeholder.
    public enum Kind: String, CaseIterable, Sendable {
        case card, iban, key, code, password, seed

        /// The placeholder the original text is replaced with.
        public var placeholder: String {
            switch self {
            case .card: "[card number]"
            case .iban: "[IBAN]"
            case .key: "[key]"
            case .code: "[code]"
            case .password: "[password]"
            case .seed: "[seed phrase]"
            }
        }
    }

    public struct Result: Equatable, Sendable {
        public var text: String
        /// How many things were replaced, by kind.
        public var counts: [Kind: Int]

        public var total: Int { counts.values.reduce(0, +) }
    }

    /// The text with private key blocks, seed phrases, card numbers (Luhn-checked), IBANs
    /// (checksum-checked), keys and tokens of common shapes, one-time codes near words like
    /// "code" and passwords after a label replaced. Line breaks are kept.
    public static func mask(_ text: String) -> Result {
        var counts: [Kind: Int] = [:]
        var out = text
        for rule in rules {
            out = rule.apply(out) { counts[rule.kind, default: 0] += 1 }
        }
        return Result(text: out, counts: counts)
    }

    // MARK: Rules, in order

    private struct Rule: @unchecked Sendable {
        /// Which shorter parts of a candidate the check tries when the whole fails: a card number
        /// followed by its expiry ("4111 … 1111 12/28") or an IBAN by a year is still found.
        enum Trim { case none, end, both }

        var kind: Kind
        var regex: NSRegularExpression?
        /// The capture group that is replaced (0: the whole match).
        var group = 0
        /// Whether a candidate is really one (a checksum); nil takes every match.
        var accept: ((String) -> Bool)?
        var trim = Trim.none
        /// Finds candidates without a regex (seed phrases).
        var find: ((NSString) -> [NSRange])?

        init(kind: Kind, regex: NSRegularExpression, group: Int = 0, accept: ((String) -> Bool)? = nil, trim: Trim = .none) {
            self.kind = kind
            self.regex = regex
            self.group = group
            self.accept = accept
            self.trim = trim
        }

        init(kind: Kind, find: @escaping (NSString) -> [NSRange]) {
            self.kind = kind
            self.find = find
        }

        func apply(_ text: String, counted: () -> Void) -> String {
            let ns = text as NSString
            let candidates: [NSRange]
            if let find {
                candidates = find(ns)
            } else if let regex {
                candidates = regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { $0.range(at: group) }
            } else {
                return text
            }
            var result = ""
            var last = 0
            for candidate in candidates {
                guard candidate.location != NSNotFound, candidate.location >= last,
                      let range = accepted(candidate, in: ns) else { continue }
                result += ns.substring(with: NSRange(location: last, length: range.location - last)) + kind.placeholder
                last = range.location + range.length
                counted()
            }
            guard last > 0 else { return text }
            return result + ns.substring(from: last)
        }

        /// The part of a candidate that is masked: the whole, or (with `trim`) its longest part
        /// on group boundaries that passes the check; nil when none does.
        private func accepted(_ range: NSRange, in ns: NSString) -> NSRange? {
            let found = ns.substring(with: range)
            if ScreenMask.placeholders.contains(found) { return nil }
            guard let accept else { return range }
            if accept(found) { return range }
            guard trim != .none else { return nil }
            let groups = ScreenMask.groupPattern.matches(in: found, range: NSRange(location: 0, length: (found as NSString).length)).map(\.range)
            guard groups.count > 1 else { return nil }
            var spans: [NSRange] = []
            for first in 0..<(trim == .end ? 1 : groups.count) {
                for end in first..<groups.count where !(first == 0 && end == groups.count - 1) {
                    let start = groups[first].location
                    spans.append(NSRange(location: start, length: groups[end].location + groups[end].length - start))
                }
            }
            for span in spans.sorted(by: { $0.length > $1.length }) where accept((found as NSString).substring(with: span)) {
                return NSRange(location: range.location + span.location, length: span.length)
            }
            return nil
        }
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are constants: a typo fails the tests at once.
        try! NSRegularExpression(pattern: pattern, options: [])
    }

    static let placeholders = Set(Kind.allCases.map(\.placeholder))
    private static let groupPattern = regex(#"[A-Za-z0-9]+"#)

    /// Words that put a password right after them ("Password: hunter2", "Passwort = …").
    static let passwordLabels = "password|passwort|kennwort|passwd|pwd|passcode|pin|mot de passe|contraseña"
    /// Words that name a secret in a label, also inside a longer name (`AWS_SECRET_ACCESS_KEY`, `SecretAccessKey`).
    static let secretLabels = #"api[_\-. ]?key|secret|token|access[_\-. ]?key|client[_\-. ]?secret|private[_\-. ]?key|auth[_\-. ]?key|credential|session[_\-. ]?key"#
    /// Words that make a short number nearby a one-time code.
    static let codeWords = "code|codes|otp|tan|2fa|mfa|verification|verify|bestätigungscode|sicherheitscode|einmalcode|anmeldecode|bestätigung|one-time|einmal|passcode|sign[ \\-]?in|log[ \\-]?in|anmelden|anmeldung"
    /// Words after "password is" that describe it instead of being it ("Your password is incorrect").
    static let notAPassword: Set<String> = ["incorrect", "wrong", "required", "invalid", "too", "not", "expired", "correct", "missing",
                                            "empty", "changed", "reset", "weak", "strong", "saved", "updated", "set", "case", "a", "an",
                                            "the", "being", "now", "falsch", "ungültig", "erforderlich", "abgelaufen", "nicht", "zu",
                                            "geändert", "zurückgesetzt", "schwach", "stark", "gespeichert", "ein", "eine", "jetzt"]

    private static let rules: [Rule] = [
        // A PEM block, whole: everything between BEGIN and END goes (to the end of the text when
        // the END isn't there), and body lines right above an END whose BEGIN was scrolled away.
        Rule(kind: .key, regex: regex(#"-----BEGIN [A-Z0-9 ]+-----[\s\S]*?(?:-----END [A-Z0-9 ]+-----|\z)"#)),
        Rule(kind: .key, regex: regex(#"(?:[A-Za-z0-9+/=]{4,}[ \t]*\n)+-----END [A-Z0-9 ]+-----"#)),
        // A wallet's seed phrase: 12 or more BIP39 words in a row (numbered or one per line too).
        Rule(kind: .seed, find: seedPhrases),
        // A password inside a connection string (postgres://user:pass@host).
        Rule(kind: .password, regex: regex(#"(?i)\b[a-z][a-z0-9+.\-]{1,20}://[^\s:/@]+:([^\s@/]+)@"#), group: 1),
        // Webhook URLs post on their own.
        Rule(kind: .key, regex: regex(#"https://hooks\.slack\.com/(?:services|workflows|triggers)/[A-Za-z0-9/_\-]+"#)),
        Rule(kind: .key, regex: regex(#"https://(?:ptb\.|canary\.)?discord(?:app)?\.com/api/webhooks/\d+/[A-Za-z0-9_\-]+"#)),
        // A password after its label, also as part of a name (`DB_PASSWORD=…`) and on the next line.
        Rule(kind: .password, regex: regex(#"(?i)(?<![A-Za-z])(?:"# + passwordLabels + #")(?:[_.\-][A-Za-z0-9_.\-]*)?["']?\s*[:=]\s*["']?([^\s"']+)"#), group: 1),
        // … in a sentence ("my password is hunter2", "Dein PIN lautet 4711") …
        Rule(kind: .password, regex: regex(#"(?i)(?<![A-Za-z])(?:"# + passwordLabels + #")\s+(?:is|ist|lautet|was|war|are|sind)\s*:?\s*["']?([^\s"'.,;!?]+)"#),
             group: 1, accept: { !notAPassword.contains($0.lowercased()) }),
        // … a PIN without a colon ("PIN 1234") …
        Rule(kind: .password, regex: regex(#"(?i)(?<![A-Za-z])pin(?:[ \-]?code)?[ \t]+(\d{4,8})(?!\d)"#), group: 1),
        // … or a label alone with one word on the next line (two separate texts on screen).
        Rule(kind: .password, regex: regex(#"(?im)^[ \t]*(?:"# + passwordLabels + #")[ \t]*:?[ \t]*\n[ \t]*(\S{1,64})[ \t]*$"#), group: 1),
        // Keys and tokens with a known prefix.
        Rule(kind: .key, regex: regex(#"\bsk-(?:ant-|proj-|live-)?[A-Za-z0-9_\-]{20,}"#)),
        Rule(kind: .key, regex: regex(#"\b(?:sk|pk|rk)_(?:live|test)_[A-Za-z0-9]{16,}"#)),
        Rule(kind: .key, regex: regex(#"\bgh[pousr]_[A-Za-z0-9]{30,}"#)),
        Rule(kind: .key, regex: regex(#"\bgithub_pat_[A-Za-z0-9_]{30,}"#)),
        Rule(kind: .key, regex: regex(#"\b(?:xox[abprse]|xapp)-[A-Za-z0-9\-]{10,}"#)),
        Rule(kind: .key, regex: regex(#"(?<![A-Z0-9])(?:AKIA|ASIA)[0-9A-Z]{16}(?![0-9A-Z])"#)),
        Rule(kind: .key, regex: regex(#"\bAIza[0-9A-Za-z_\-]{30,}"#)),
        Rule(kind: .key, regex: regex(#"\bglpat-[A-Za-z0-9_\-]{20,}"#)),
        Rule(kind: .key, regex: regex(#"\bnpm_[A-Za-z0-9]{30,}"#)),
        Rule(kind: .key, regex: regex(#"\bhf_[A-Za-z0-9]{30,}"#)),
        Rule(kind: .key, regex: regex(#"\beyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#)),
        Rule(kind: .key, regex: regex(#"(?i)\bbearer\s+([A-Za-z0-9._~+/\-]{16,}=*)"#), group: 1),
        // A labelled secret: only a value with letters and digits mixed ("token: expired" stays).
        Rule(kind: .key,
             regex: regex(#"(?i)(?<![A-Za-z0-9])[A-Za-z0-9_.\-]*?(?:"# + secretLabels + #")[A-Za-z0-9_.\-]*["']?\s*[:=]\s*["']?([A-Za-z0-9._~+/=\-]{12,})"#),
             group: 1, accept: mixed),
        // … or a label alone with the value on the next line.
        Rule(kind: .key, regex: regex(#"(?im)^[ \t]*(?:"# + secretLabels + #")[ \t]*:?[ \t]*\n[ \t]*([A-Za-z0-9._~+/=\-]{12,})[ \t]*$"#),
             group: 1, accept: mixed),
        // IBAN: country, check digits, then groups; only with a valid checksum.
        Rule(kind: .iban, regex: regex(#"(?i)\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,4})?\b"#), accept: isIBAN, trim: .end),
        // Card numbers: 13 to 19 digits, spaces or dashes between, Luhn-valid.
        Rule(kind: .card, regex: regex(#"(?<![\d.,])(?:\d[ \-]?){12,18}\d(?![\d.,]\d)"#), accept: isCardNumber, trim: .both),
        // A card's security code: after its label, or the short number right after a card number
        // (and its expiry), also as a separate text.
        Rule(kind: .code, regex: regex(#"(?i)(?<![A-Za-z])(?:cvc2?|cvv2?|cid|csc|security code|card code|sicherheitscode|kartenprüfnummer|prüfnummer|prüfziffer)(?![A-Za-z])[\s:=]{0,8}(\d{3,4})(?!\d)"#),
             group: 1),
        Rule(kind: .code, regex: regex(#"\[card number\][^\d\[]{0,12}(?:\d{2}\s*/\s*\d{2,4}[^\d\[]{0,12})?(?<!\d)(\d{3,4})(?!\d)"#), group: 1),
        // Google's "G-482913".
        Rule(kind: .code, regex: regex(#"(?<![A-Za-z0-9\-])G-\d{6}(?!\d)"#)),
        // A one-time code after a code word ("Your code: 482 913", "TAN 123456") …
        Rule(kind: .code, regex: regex(#"(?i)(?<!zip |postal |area |error |status |country |source )\b(?:"# + codeWords + #")\b[^\d\n]{0,24}?(?<![\d\-/.:])(\d{3}[ \-]?\d{3}|\d{4,8})(?![\d\-/.:]\d)"#),
             group: 1, accept: isCode),
        // … or before one ("482913 is your verification code", "Use 739204 to sign in").
        Rule(kind: .code, regex: regex(#"(?i)(?<![\d\-/.:])(\d{3}[ \-]?\d{3}|\d{4,8})(?![\d\-/.:]\d)(?=[^\d\n]{0,24}\b(?:"# + codeWords + #")\b)"#),
             group: 1, accept: isCode),
        // Anything that looks like a key without a label: 40 or more characters of upper and lower
        // case letters and digits (an AWS secret key on its own, a key file's body line).
        Rule(kind: .key, regex: regex(#"(?<![A-Za-z0-9+/=_\-])[A-Za-z0-9+/=_\-]{40,}(?![A-Za-z0-9+/=_\-])"#), accept: looksRandom),
    ]

    // MARK: Checks

    /// Letters and digits mixed.
    static func mixed(_ value: String) -> Bool {
        value.contains(where: \.isNumber) && value.contains(where: \.isLetter)
    }

    /// Upper and lower case letters and digits: a key, not a word, a hash (lower-case hex) or a path.
    static func looksRandom(_ value: String) -> Bool {
        value.contains(where: \.isUppercase) && value.contains(where: \.isLowercase) && value.contains(where: \.isNumber)
            && !value.contains("//")
    }

    /// Runs of 12 or more words from the BIP39 list, with only spaces, line breaks, numbers and
    /// punctuation between them ("1. abandon 2. ability …").
    static func seedPhrases(_ text: NSString) -> [NSRange] {
        var found: [NSRange] = []
        var run: [NSRange] = []
        func close() {
            if run.count >= 12, let first = run.first, let last = run.last {
                found.append(NSRange(location: first.location, length: last.location + last.length - first.location))
            }
            run = []
        }
        for match in wordPattern.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
            let word = text.substring(with: match.range).lowercased()
            guard bip39.contains(word) else { close(); continue }
            if let previous = run.last {
                let gapStart = previous.location + previous.length
                let gap = text.substring(with: NSRange(location: gapStart, length: match.range.location - gapStart))
                if !gap.allSatisfy({ $0.isWhitespace || $0.isNumber || ".,:;)-".contains($0) }) { close() }
            }
            run.append(match.range)
        }
        close()
        return found
    }

    private static let wordPattern = regex(#"[A-Za-z]+"#)

    /// Luhn-valid, 13 to 19 digits, a card network's first digit (2–6), not one digit repeated.
    public static func isCardNumber(_ candidate: String) -> Bool {
        let digits = candidate.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count), let first = digits.first, (2...6).contains(first),
              Set(digits).count > 1 else { return false }
        return luhn(digits)
    }

    public static func luhn(_ digits: [Int]) -> Bool {
        var sum = 0
        for (index, digit) in digits.reversed().enumerated() {
            if index % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }

    /// A valid IBAN: 15 to 34 characters, the mod-97 check passes.
    public static func isIBAN(_ candidate: String) -> Bool {
        let compact = candidate.filter { !$0.isWhitespace }.uppercased()
        guard (15...34).contains(compact.count), compact.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return false }
        let rearranged = compact.dropFirst(4) + compact.prefix(4)
        var remainder = 0
        for char in rearranged {
            let value: Int
            if let digit = char.wholeNumberValue {
                value = digit
            } else if let ascii = char.asciiValue {
                value = Int(ascii) - 55  // A = 10
            } else {
                return false
            }
            for part in value >= 10 ? [value / 10, value % 10] : [value] {
                remainder = (remainder * 10 + part) % 97
            }
        }
        return remainder == 1
    }

    /// A code, not a year ("Code review 2026"): four digits from 1900 to 2099 stay.
    static func isCode(_ candidate: String) -> Bool {
        let digits = candidate.filter(\.isNumber)
        if digits.count == 4, let year = Int(digits), (1900...2099).contains(year) { return false }
        return digits.count >= 4
    }
}
