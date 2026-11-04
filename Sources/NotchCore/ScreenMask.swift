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
    /// "code" and passwords after a label replaced. Line breaks are kept. The keys this Mac already
    /// holds (`known`) go first, whatever their shape; gitleaks' rules run after the known prefixes,
    /// each only when the text holds one of its keywords.
    public static func mask(_ text: String, known: KnownSecrets = .current) -> Result {
        var counts: [Kind: Int] = [:]
        var out = text
        let upstreamRules = upstream(for: text).map { Rule(kind: .key, find: secrets($0.rule, $0.regex)) }
        for rule in (known.isEmpty ? [] : [Rule(kind: .key, find: known.ranges)]) + rules + upstreamRules + laterRules {
            out = rule.apply(out) { counts[rule.kind, default: 0] += 1 }
        }
        return Result(text: out, counts: counts)
    }

    /// Whether a page's address is one for API keys or tokens (`/settings/keys`, `/api-keys`,
    /// `/tokens`, `/credentials`, anything under `/security/` …): such a page isn't read at all, so
    /// a key it shows once never has to be caught by a rule. Only http and https addresses.
    public static func isKeyPage(_ url: String) -> Bool {
        guard let parts = URLComponents(string: url), let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return false }
        let place = parts.percentEncodedPath + (parts.percentEncodedFragment.map { "#" + $0 } ?? "")
        return keyPagePattern.firstMatch(in: place, range: NSRange(location: 0, length: (place as NSString).length)) != nil
    }

    /// A whole path segment (or a fragment, as in `#/security_credentials`), `/settings/api` (Supabase,
    /// Linear) and anything under `/security/`.
    private static let keyPagePattern = regex(#"(?i)[/#](?:keys|api[\-_]?keys?|(?:api|access|personal[\-_]access|auth)[\-_]?tokens|tokens"#
                                              + #"|credentials|security[\-_]credentials|secrets|environment-variables|my-integrations)(?:[/?#]|$)"#
                                              + #"|/settings/api(?:[\-_/?#]|$)|/security/"#)

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
    /// Words that name a secret in a label, also inside a longer name (`AWS_SECRET_ACCESS_KEY`, `SecretAccessKey`,
    /// `API-Schlüssel`, `Zugangsschlüssel`, `DatenbankPasswort`): English, German, and the key words of
    /// French, Spanish, Italian, Portuguese and Dutch.
    static let secretLabels = #"api[_\-. ]?key|secret|token|access[_\-. ]?key|client[_\-. ]?secret|private[_\-. ]?key|auth[_\-. ]?key|credential|session[_\-. ]?key"#
        + #"|schlüssel|geheim|zugangsdaten|passw(?:or)?d|passwort|kennwort"#
        + #"|cl[eé] api|cl[eé] secr[eè]te|clave api|clave secreta|chiave api|chiave segreta|chave api|sleutel"#
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
        // More prefixes, each from the provider's documented or detected shape (gitleaks, TruffleHog,
        // Google's OSV-SCALIBR, the Stripe CLI). A rare prefix takes any long tail; a common one only
        // its exact shape. Brevo's API and SMTP keys (64 hex, a dash, 16 more):
        Rule(kind: .key, regex: regex(#"\bx(?:keysib|smtpsib)-[A-Za-z0-9_\-]{20,}"#)),
        // Supabase's secret and personal keys (sb_publishable_ is public by design and stays):
        Rule(kind: .key, regex: regex(#"\bsb_secret_[A-Za-z0-9_\-]{31,}"#)),
        Rule(kind: .key, regex: regex(#"\bsbp_[a-z0-9]{40}(?![A-Za-z0-9_])"#)),
        // Stripe's webhook signing secrets:
        Rule(kind: .key, regex: regex(#"\bwhsec_[A-Za-z0-9+/]{32,}=*"#)),
        // Resend: re_, 8 characters, an underscore, 24 more; only with a capital or a digit after the
        // prefix, so a snake_case name of that length stays.
        Rule(kind: .key, regex: regex(#"\bre_[1-9A-HJ-NP-Za-km-z]{8}_[1-9A-HJ-NP-Za-km-z]{24}(?![A-Za-z0-9_])"#),
             accept: { $0.dropFirst(3).contains { $0.isUppercase || $0.isNumber } }),
        // Groq, xAI, Replicate, Google's OAuth client secrets, LangSmith, ElevenLabs.
        Rule(kind: .key, regex: regex(#"\bgsk_[A-Za-z0-9]{20,}"#)),
        Rule(kind: .key, regex: regex(#"\bxai-[A-Za-z0-9_]{20,}"#)),
        Rule(kind: .key, regex: regex(#"\br8_[A-Za-z0-9_\-]{20,}"#)),
        Rule(kind: .key, regex: regex(#"\bGOCSPX-[A-Za-z0-9_\-]{20,}"#)),
        Rule(kind: .key, regex: regex(#"\blsv2_(?:pt|sk)_[a-f0-9]{32}_[a-f0-9]{10}(?![A-Za-z0-9_])"#)),
        Rule(kind: .key, regex: regex(#"\bsk_[a-f0-9]{48}(?![A-Za-z0-9_])"#)),
    ]

    // gitleaks' rules (`upstream`) run here, between the known prefixes and the labels.

    private static let laterRules: [Rule] = [
        // A labelled secret: only a value with letters and digits mixed ("token: expired" stays).
        Rule(kind: .key,
             regex: regex(#"(?i)(?<![A-Za-z0-9])[A-Za-z0-9_.\-]*?(?:"# + secretLabels + #")[A-Za-z0-9_.\-]*["']?\s*[:=]\s*["']?([A-Za-z0-9._~+/=\-]{12,})"#),
             group: 1, accept: mixed),
        // … or a label alone with the value on the next line ("API-Schlüssel", "Your API key").
        Rule(kind: .key, regex: regex(#"(?im)^[ \t]*(?:\S+[ \t]+){0,3}?[A-Za-z0-9_.\-]*?(?:"# + secretLabels
                                      + #")[A-Za-z0-9_.\-]*[ \t]*:?[ \t]*\n[ \t]*([A-Za-z0-9._~+/=\-]{12,})[ \t]*$"#),
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
        // The net for keys of any other shape: 32 or more characters that look random (`looksLikeKey`).
        // A slash, a dot or a colon ends a candidate, so only the random part of a URL or a file name goes.
        Rule(kind: .key, regex: regex(#"(?<![A-Za-z0-9+_\-])[A-Za-z0-9+_\-]{32,}=*(?![A-Za-z0-9+_\-=])"#), accept: looksLikeKey),
    ]

    // MARK: gitleaks

    /// One of gitleaks' rules (ScreenMaskGitleaks.swift, generated from its config): as in gitleaks,
    /// its regex runs only when the text, in lower case, contains one of its keywords.
    struct UpstreamRule: Sendable {
        var id: String
        var keywords: [String]
        var pattern: String
        /// The capture group with the secret; 0: the first group that matched, else the whole match.
        var group = 0
        /// The secret's Shannon entropy must be above this (0: any).
        var entropy = 0.0
    }

    /// gitleaks' rules whose regex compiles here (all of them, when the generated file is current).
    static let upstream: [(rule: UpstreamRule, regex: NSRegularExpression)] = gitleaksRules.compactMap { rule in
        (try? NSRegularExpression(pattern: rule.pattern, options: [])).map { (rule, $0) }
    }

    private static let upstreamKeywords = Set(upstream.flatMap(\.rule.keywords))

    /// The upstream rules worth running on a text: those with a keyword in it. A literal search in
    /// an NSString: String.contains took a hundred milliseconds for a full screen.
    static func upstream(for text: String) -> [(rule: UpstreamRule, regex: NSRegularExpression)] {
        let lower = text.lowercased() as NSString
        let present = upstreamKeywords.filter { lower.range(of: $0, options: .literal).location != NSNotFound }
        return present.isEmpty ? [] : upstream.filter { !present.isDisjoint(with: $0.rule.keywords) }
    }

    /// Where an upstream rule's secrets stand: its secret group, or the first group that matched, or
    /// the whole match; only a secret varied enough for the rule's entropy.
    private static func secrets(_ rule: UpstreamRule, _ regex: NSRegularExpression) -> (NSString) -> [NSRange] {
        { text in
            regex.matches(in: text as String, range: NSRange(location: 0, length: text.length)).compactMap { match in
                let range = rule.group > 0
                    ? (rule.group < match.numberOfRanges ? match.range(at: rule.group) : NSRange(location: NSNotFound, length: 0))
                    : (1..<match.numberOfRanges).lazy.map(match.range(at:)).first { $0.location != NSNotFound && $0.length > 0 } ?? match.range
                guard range.location != NSNotFound, range.length > 0 else { return nil }
                if rule.entropy > 0, entropy(text.substring(with: range)) <= rule.entropy { return nil }
                return range
            }
        }
    }

    // MARK: Checks

    /// Letters and digits mixed.
    static func mixed(_ value: String) -> Bool {
        value.contains(where: \.isNumber) && value.contains(where: \.isLetter)
    }

    /// Upper and lower case letters and digits: a key, not a word, a hash (lower-case hex) or a path.
    /// A URL's path has a word between two slashes; its random part is left to `looksLikeKey`. A
    /// file name in camelCase switches too rarely (`switchRate`, a little below the net's 0.25, as
    /// this rule already asks for all three kinds of characters).
    static func looksRandom(_ value: String) -> Bool {
        value.contains(where: \.isUppercase) && value.contains(where: \.isLowercase) && value.contains(where: \.isNumber)
            && !value.contains("//") && !value.split(separator: "/").contains { $0.count >= 3 && $0.allSatisfy(\.isLowercase) }
            && switchRate(value) >= 0.2 && !publicPrefixes.contains(where: value.hasPrefix)
    }

    /// A key of unknown shape: letters and digits mixed, as varied as a key and not made of words.
    /// UUIDs, commit IDs (40 hex) and SHA-256 digests (64 hex) stay: that is what long hex on a
    /// screen usually is, and a key of that shape with a label is still caught by the label rules.
    static func looksLikeKey(_ candidate: String) -> Bool {
        let value = String(candidate.reversed().drop { $0 == "=" }.reversed())
        guard value.count >= 32, mixed(value), !publicPrefixes.contains(where: value.hasPrefix),
              uuidPattern.firstMatch(in: value, range: NSRange(location: 0, length: (value as NSString).length)) == nil else { return false }
        let hex = value.allSatisfy(\.isHexDigit) && (value == value.lowercased() || value == value.uppercased())
        if hex, value.count == 40 || value.count == 64 { return false }
        // Shannon entropy in bits per character: gitleaks' threshold for keys (3.5), detect-secrets'
        // for hex (3.0). Then the switches: random text changes between letters and digits, or from
        // a small letter to a capital, at about every second character; names, slugs, file names and
        // camelCase rarely do (`how-to-build-a-notch-app-2026`: 0.05, `iPhone15ProScreenRecording20261104`:
        // 0.18, a random key: 0.4 to 0.6).
        return entropy(value) >= (hex ? 3.0 : 3.5) && switchRate(value) >= 0.25
    }

    /// Keys that are public by design.
    static let publicPrefixes = ["sb_publishable_"]
    private static let uuidPattern = regex(#"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#)

    /// Shannon entropy of the characters, in bits per character.
    static func entropy(_ value: String) -> Double {
        var counts: [Character: Int] = [:]
        for char in value { counts[char, default: 0] += 1 }
        let total = Double(value.count)
        return counts.values.reduce(0) { sum, count in
            let share = Double(count) / total
            return sum - share * log2(share)
        }
    }

    /// How often the letters and digits switch between letter and digit, or from a small letter to a
    /// capital, per pair of neighbours (other characters skipped).
    static func switchRate(_ value: String) -> Double {
        let chars = value.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        guard chars.count > 1 else { return 0 }
        var switches = 0
        for (a, b) in zip(chars, chars.dropFirst()) where a.isNumber != b.isNumber || (a.isLowercase && b.isUppercase) {
            switches += 1
        }
        return Double(switches) / Double(chars.count - 1)
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
