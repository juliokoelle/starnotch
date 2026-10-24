import Foundation

/// One run of a loop (a recurring agent or job): its day, outcome and one line of note.
public struct LoopRun: Equatable, Sendable {
    public enum Status: String, Sendable {
        case ok, degraded, skip, fail, test, unknown
    }

    /// `YYYY-MM-DD`, the day of the run.
    public var day: String
    public var loop: String
    public var status: Status
    public var note: String

    public init(day: String, loop: String, status: Status, note: String) {
        self.day = day
        self.loop = loop
        self.status = status
        self.note = note
    }
}

/// What the notch knows about one loop. A `JobsProvider` fills it; the local API adds the live
/// part (running, waiting, progress).
public struct LoopStatus: Equatable, Sendable, Identifiable {
    public var id: String { name }
    /// Stable slug, e.g. "morning-brief"; the local API's `loop=` refers to it.
    public var name: String
    /// What the notch shows, e.g. "Morning brief".
    public var displayName: String
    public var last: LoopRun?
    public var nextRun: Date?
    /// No run logged today or yesterday although the loop is scheduled.
    public var isLate: Bool
    /// The last runs, oldest first.
    public var history: [LoopRun]
    /// Today's scheduled runs with their outcome.
    public var slots: [LoopTimeline.Slot]
    /// The last message the loop delivered, where its result lives, and when.
    public var outbox: String?
    public var outboxLink: URL?
    public var outboxDate: Date?
    /// Where the loop is defined (its spec or script), if anywhere.
    public var specURL: URL?
    /// From the local API: a run in progress, and since when.
    public var isRunning = false
    public var runningSince: Date?
    public var progress: Double?
    /// From the local API: the loop waits on the user.
    public var isWaiting = false

    public init(name: String, displayName: String? = nil, last: LoopRun? = nil, nextRun: Date? = nil,
                isLate: Bool = false, history: [LoopRun] = [], slots: [LoopTimeline.Slot] = [],
                outbox: String? = nil, outboxLink: URL? = nil, outboxDate: Date? = nil, specURL: URL? = nil) {
        self.name = name
        self.displayName = displayName ?? LoopStatus.displayName(name)
        self.last = last
        self.nextRun = nextRun
        self.isLate = isLate
        self.history = history
        self.slots = slots
        self.outbox = outbox
        self.outboxLink = outboxLink
        self.outboxDate = outboxDate
        self.specURL = specURL
    }

    /// "morning-brief" → "Morning brief".
    public static func displayName(_ slug: String) -> String {
        let words = slug.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        guard let first = words.first else { return slug }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
    }
}

public enum LoopTimeline {
    public struct Slot: Equatable, Sendable {
        public var at: Date
        /// `nil` = still to come.
        public var status: LoopRun.Status?
        /// Scheduled and past, but no run logged for it.
        public var missed: Bool

        public init(at: Date, status: LoopRun.Status?, missed: Bool = false) {
            self.at = at
            self.status = status
            self.missed = missed
        }
    }

    /// Today's scheduled runs, the past ones paired in order with today's logged runs. Runs with
    /// `skip` (one that found nothing to do or the wrong window) still count as runs.
    public static func today(schedules: [CronSchedule], entries: [LoopRun], dayStart: Date, now: Date) -> [Slot] {
        var times: [Date] = []
        var cursor = dayStart.addingTimeInterval(-1)
        let dayEnd = dayStart.addingTimeInterval(86_400)
        while times.count < 48 {
            guard let next = schedules.compactMap({ $0.next(after: cursor) }).min(), next < dayEnd else { break }
            times.append(next)
            cursor = next
        }
        var remaining = entries[...]
        return times.map { time in
            guard time <= now else { return Slot(at: time, status: nil) }
            if let entry = remaining.first {
                remaining = remaining.dropFirst()
                return Slot(at: time, status: entry.status)
            }
            return Slot(at: time, status: nil, missed: true)
        }
    }
}
