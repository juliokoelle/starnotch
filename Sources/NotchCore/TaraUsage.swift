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
        /// Calls per feature (`ask`, `capture`, `meeting`, or whatever a newer sidecar writes).
        public var byFeature: [String: Int] = [:]

        public init() {}

        mutating func add(_ call: Call) {
            calls += 1
            tokens += call.tokens
            cachedTokens += call.cacheReadTokens
            costUSD += call.costUSD ?? 0
            byFeature[call.feature, default: 0] += 1
        }
    }

    public struct Summary: Equatable, Sendable {
        public var today = Totals()
        /// Today and the six days before it.
        public var week = Totals()

        public init() {}
    }

    /// Every readable line; lines that aren't JSON or have no time are skipped.
    public static func parse(_ text: String) -> [Call] {
        let iso = ISO8601DateFormatter()
        return text.split(whereSeparator: \.isNewline).compactMap { line in
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

    public static func summary(_ calls: [Call], now: Date, calendar: Calendar = .current) -> Summary {
        let today = calendar.startOfDay(for: now)
        let weekStart = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        var summary = Summary()
        for call in calls where call.time <= now {
            if call.time >= weekStart { summary.week.add(call) }
            if call.time >= today { summary.today.add(call) }
        }
        return summary
    }

    /// The ledger in `folder`; an empty summary when there is none yet.
    public static func load(folder: URL, now: Date = Date()) -> Summary {
        let text = (try? String(contentsOf: folder.appending(path: fileName), encoding: .utf8)) ?? ""
        return summary(parse(text), now: now)
    }

    /// 950, 12k, 1.2M.
    public static func compact(_ tokens: Int) -> String {
        switch tokens {
        case ..<1_000: "\(tokens)"
        case ..<100_000: trimmed(Double(tokens) / 1_000) + "k"
        case ..<999_500: "\(Int((Double(tokens) / 1_000).rounded()))k"
        default: trimmed(Double(tokens) / 1_000_000) + "M"
        }
    }

    /// $0.62, $12.40, "< $0.01" for a little more than nothing, $0 for nothing.
    public static func dollars(_ amount: Double) -> String {
        if amount <= 0 { return "$0" }
        if amount < 0.01 { return "< $0.01" }
        return String(format: "$%.2f", locale: Locale(identifier: "en_US_POSIX"), amount)
    }

    private static func trimmed(_ value: Double) -> String {
        let text = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
}
