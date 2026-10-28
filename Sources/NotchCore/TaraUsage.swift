import Foundation

// Tara's usage ledger (agent/usage.py): one JSON line per brain call in `usage.jsonl` in the app's folder,
// summed for Settings. Read only; the sidecar writes and prunes it.

public enum TaraUsage {
    public static let fileName = "usage.jsonl"

    /// What a call was for, as the sidecar writes it.
    public enum Feature: String, CaseIterable, Sendable {
        /// Ask Tara.
        case ask
        /// A question typed into quick capture.
        case capture
        /// The live meeting analysis, one call per batch of new utterances.
        case meeting
    }

    public struct Call: Equatable, Sendable {
        public var time: Date
        public var feature: String
        public var brain: String
        public var model: String
        public var inputTokens: Int
        public var cacheWriteTokens: Int
        public var cacheReadTokens: Int
        public var outputTokens: Int
        public var durationMs: Int
        /// At API list prices; nil when the sidecar couldn't price the model.
        public var costUSD: Double?

        public var tokens: Int { inputTokens + cacheWriteTokens + cacheReadTokens + outputTokens }
    }

    public struct Totals: Equatable, Sendable {
        public var calls = 0
        public var tokens = 0
        public var cachedTokens = 0
        public var costUSD = 0.0
        /// Calls the sidecar couldn't price (a model outside its price table): `costUSD` leaves them out.
        public var unpricedCalls = 0
        /// Calls per feature (`ask`, `capture`, `meeting`, or whatever a newer sidecar writes).
        public var byFeature: [String: Int] = [:]

        public init() {}

        mutating func add(_ call: Call) {
            calls += 1
            tokens += call.tokens
            cachedTokens += call.cacheReadTokens
            if let cost = call.costUSD { costUSD += cost } else { unpricedCalls += 1 }
            byFeature[call.feature, default: 0] += 1
        }
    }

    public struct Summary: Equatable, Sendable {
        public var today = Totals()
        /// Today and the six days before it.
        public var week = Totals()

        public init() {}
    }

    /// Every readable line; lines that aren't JSON or have no time are skipped. With `since`, lines written before
    /// it are skipped from their first characters, before any JSON parsing: the ledger keeps 90 days and Settings
    /// shows 7.
    public static func parse(_ text: String, since: Date? = nil) -> [Call] {
        let iso = ISO8601DateFormatter()
        let cutoff = since.map { Array(iso.string(from: $0).utf8) }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            if let cutoff, let stamp = leadingTime(line), stamp.lexicographicallyPrecedes(cutoff) { return nil }
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let stamp = object["time"] as? String, let time = iso.date(from: stamp) else { return nil }
            func int(_ key: String) -> Int { (object[key] as? NSNumber)?.intValue ?? 0 }
            return Call(time: time, feature: object["feature"] as? String ?? "", brain: object["brain"] as? String ?? "",
                        model: object["model"] as? String ?? "", inputTokens: int("input_tokens"),
                        cacheWriteTokens: int("cache_creation_input_tokens"),
                        cacheReadTokens: int("cache_read_input_tokens"), outputTokens: int("output_tokens"),
                        durationMs: int("duration_ms"), costUSD: (object["cost_usd"] as? NSNumber)?.doubleValue)
        }
    }

    /// `usage.py` writes `{"time": "2026-10-28T09:12:03Z", …`: the time's 20 bytes, nil for a line in another shape.
    private static let timePrefix = Array(#"{"time": ""#.utf8)

    private static func leadingTime(_ line: Substring) -> [UInt8]? {
        let bytes = line.utf8
        guard bytes.starts(with: timePrefix) else { return nil }
        let stamp = bytes.dropFirst(timePrefix.count).prefix(20)
        return stamp.count == 20 ? Array(stamp) : nil
    }

    /// The start of today and of the six days before it.
    static func weekStart(now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -6, to: today) ?? today
    }

    public static func summary(_ calls: [Call], now: Date, calendar: Calendar = .current) -> Summary {
        let today = calendar.startOfDay(for: now)
        let weekStart = weekStart(now: now, calendar: calendar)
        var summary = Summary()
        for call in calls where call.time <= now {
            if call.time >= weekStart { summary.week.add(call) }
            if call.time >= today { summary.today.add(call) }
        }
        return summary
    }

    /// The ledger in `folder`; an empty summary when there is none yet. It reads the whole file (up to 90 days of
    /// calls, megabytes after heavy meeting use): call it off the main actor.
    public static func load(folder: URL, now: Date = Date(), calendar: Calendar = .current) -> Summary {
        let text = (try? String(contentsOf: folder.appending(path: fileName), encoding: .utf8)) ?? ""
        return summary(parse(text, since: weekStart(now: now, calendar: calendar)), now: now, calendar: calendar)
    }

    /// The ledger's modification date, nil when there is none: Settings re-reads only when it changes.
    public static func modified(folder: URL) -> Date? {
        let path = folder.appending(path: fileName).path
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// ` --usage '<folder>/usage.jsonl'` for `agent.py`, so the sidecar writes where Settings reads.
    public static func argument(folder: URL) -> String {
        " --usage " + SetupActions.shellQuote(folder.appending(path: fileName).path)
    }

    /// Fixed formatting (tests, logs); Settings passes the user's locale.
    public static let posix = Locale(identifier: "en_US_POSIX")

    /// 950, 12k, 1.2M (33,1k with a German locale).
    public static func compact(_ tokens: Int, locale: Locale = posix) -> String {
        switch tokens {
        case ..<1_000: "\(tokens)"
        case ..<100_000: trimmed(Double(tokens) / 1_000, locale: locale) + "k"
        case ..<999_500: "\(Int((Double(tokens) / 1_000).rounded()))k"
        default: trimmed(Double(tokens) / 1_000_000, locale: locale) + "M"
        }
    }

    /// $0.62, $12.40, "< $0.01" for a little more than nothing, $0 for nothing ($12,40 with a German locale).
    public static func dollars(_ amount: Double, locale: Locale = posix) -> String {
        if amount <= 0 { return "$0" }
        if amount < 0.01 { return "< $" + String(format: "%.2f", locale: locale, 0.01) }
        return "$" + String(format: "%.2f", locale: locale, amount)
    }

    /// The cost of `totals`, with a + when some calls couldn't be priced and so aren't in it.
    public static func cost(_ totals: Totals, locale: Locale = posix) -> String {
        dollars(totals.costUSD, locale: locale) + (totals.unpricedCalls > 0 ? "+" : "")
    }

    private static func trimmed(_ value: Double, locale: Locale) -> String {
        let text = String(format: "%.1f", locale: locale, value)
        let zero = String(format: "%.1f", locale: locale, 0.0).dropFirst()  // ".0" or ",0"
        return text.hasSuffix(zero) ? String(text.dropLast(zero.count)) : text
    }
}
