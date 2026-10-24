import Foundation

/// One assistant message's token use, read from a Claude Code transcript line.
public struct UsageLine: Equatable, Sendable {
    public var messageID: String
    public var date: Date
    /// Input + output + cache writes. Cache reads are left out: they are cheap and would swamp
    /// everything else.
    public var tokens: Int

    /// Pulls the few fields out of a (possibly very long) JSONL line without decoding it.
    public static func parse(_ line: Substring) -> UsageLine? {
        func string(after key: String) -> Substring? {
            guard let range = line.range(of: key) else { return nil }
            return line[range.upperBound...].prefix { $0 != "\"" }
        }
        guard line.contains("\"usage\""), line.contains("\"type\":\"assistant\""),
              let id = string(after: "\"id\":\"msg_").map({ "msg_" + $0 }),
              let stamp = string(after: "\"timestamp\":\""),
              let date = SessionLog.parseDate(String(stamp)) else { return nil }
        func number(_ key: String) -> Int {
            // Plain substring search: far cheaper than a regex per line on gigabytes of logs.
            guard let range = line.range(of: "\"\(key)\":") else { return 0 }
            return Int(line[range.upperBound...].prefix { $0.isNumber }) ?? 0
        }
        let tokens = number("input_tokens") + number("output_tokens") + number("cache_creation_input_tokens")
        return UsageLine(messageID: id, date: date, tokens: tokens)
    }
}

/// Estimated Claude quota from local logs: the current 5-hour block and the last 7 days, each
/// against the highest value seen so far. Not the real limit (that isn't in the logs).
public struct QuotaEstimate: Equatable, Sendable {
    public enum Window: String, Sendable { case fiveHours, week }
    public enum Pace: Equatable, Sendable { case enough, tight }

    public var window: Window
    /// 0...1 (can pass 1 when above the previous maximum; shown capped).
    public var used: Double
    public var resets: Date?
    public var pace: Pace
    public var fiveHourUsed: Double
    public var weekUsed: Double?
    /// Absolute tokens in the current 5-hour block and the last 7 days.
    public var blockTokens: Int = 0
    public var weekTokens: Int = 0

    public init(window: Window, used: Double, resets: Date?, pace: Pace, fiveHourUsed: Double, weekUsed: Double?) {
        self.window = window
        self.used = used
        self.resets = resets
        self.pace = pace
        self.fiveHourUsed = fiveHourUsed
        self.weekUsed = weekUsed
    }
}

public enum QuotaEstimator {
    public static let blockLength: TimeInterval = 5 * 3600

    /// - Parameters:
    ///   - hourly: tokens per hour, keyed by the hour's start.
    ///   - now: the present.
    public static func estimate(hourly: [Date: Int], now: Date, calendar: Calendar = .current) -> QuotaEstimate? {
        let hours = hourly.filter { $0.value > 0 }.sorted { $0.key < $1.key }
        guard !hours.isEmpty else { return nil }

        // 5-hour blocks: a block starts at the first active hour after the previous one ended.
        var blocks: [(start: Date, total: Int)] = []
        for (hour, tokens) in hours {
            if let last = blocks.last, hour < last.start.addingTimeInterval(blockLength) {
                blocks[blocks.count - 1].total += tokens
            } else {
                blocks.append((hour, tokens))
            }
        }
        let current = blocks.last.flatMap { now < $0.start.addingTimeInterval(blockLength) ? $0 : nil }
        let completed = current == nil ? blocks : Array(blocks.dropLast())
        guard let peak = completed.map(\.total).max(), peak > 0 else { return nil }
        let fiveUsed = Double(current?.total ?? 0) / Double(peak)
        let resets = current.map { $0.start.addingTimeInterval(blockLength) }

        // Rolling 7 days against the highest 7 days that ended at an earlier day boundary.
        let week: TimeInterval = 7 * 86_400
        func total(_ from: Date, _ to: Date) -> Int { hours.filter { $0.key >= from && $0.key < to }.reduce(0) { $0 + $1.value } }
        var previousWeeks: [Int] = []
        var end = calendar.startOfDay(for: now)
        while end.timeIntervalSince(hours[0].key) >= week {
            previousWeeks.append(total(end.addingTimeInterval(-week), end))
            end = end.addingTimeInterval(-86_400)
        }
        var weekUsed: Double?
        if let best = previousWeeks.max(), best > 0 {
            weekUsed = Double(total(now.addingTimeInterval(-week), now)) / Double(best)
        }

        // Pace for the 5-hour block: used share vs. elapsed share.
        var pace = QuotaEstimate.Pace.enough
        if let current {
            let elapsed = max(0.05, now.timeIntervalSince(current.start) / blockLength)
            pace = fiveUsed / elapsed > 1 ? .tight : .enough
        }

        let useWeek = (weekUsed ?? 0) > fiveUsed
        var estimate = QuotaEstimate(window: useWeek ? .week : .fiveHours, used: useWeek ? weekUsed! : fiveUsed,
                                     resets: useWeek ? nil : resets, pace: pace, fiveHourUsed: fiveUsed, weekUsed: weekUsed)
        estimate.blockTokens = current?.total ?? 0
        estimate.weekTokens = total(now.addingTimeInterval(-week), now.addingTimeInterval(3600))
        return estimate
    }

    /// "1.2 M", "840 k", "530".
    public static func tokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1f M", Double(count) / 1_000_000) }
        if count >= 10_000 { return "\(count / 1000) k" }
        if count >= 1000 { return String(format: "%.1f k", Double(count) / 1000) }
        return "\(count)"
    }

    /// Display tint: neutral below 80 %, amber from 80 %, red from 90 %.
    public enum Level: Equatable, Sendable { case calm, warn, critical }

    public static func level(_ used: Double) -> Level {
        used >= 0.9 ? .critical : used >= 0.8 ? .warn : .calm
    }
}
