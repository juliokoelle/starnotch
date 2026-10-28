import Foundation

/// When the app syncs Jamie on its own, while a login is saved: shortly after launch, every half
/// hour, after waking when the last sync is older than that, about 5 and again 20 minutes after a
/// meeting with others ends (Jamie needs a while for the transcript), and when Ask Tara opens on a
/// sync older than ten minutes. A failed sync waits 5, 15, then 60 minutes before the next try.
public struct JamieSyncSchedule: Equatable, Sendable {
    /// What asks: the app's regular look, a wake from sleep, or Ask Tara opening.
    public enum Trigger: Sendable { case timer, wake, askOpened }

    public static let launchDelay: TimeInterval = 20
    public static let interval: TimeInterval = 30 * 60
    /// Ask Tara opening syncs in the background when the last sync is older than this.
    public static let askFreshness: TimeInterval = 10 * 60
    public static let afterMeeting: [TimeInterval] = [5 * 60, 20 * 60]
    public static let backoff: [TimeInterval] = [5 * 60, 15 * 60, 60 * 60]

    /// A login is saved and Jamie hasn't asked for a new one since; off, nothing syncs on its own.
    public var connected: Bool
    public var launched: Date
    public var lastSuccess: Date?
    public var lastFailure: Date?
    /// Failed syncs in a row; a success sets it back to 0.
    public var failures: Int
    /// When the day's calls and meetings with others end (no focus blocks).
    public var meetingEnds: [Date]

    public init(connected: Bool, launched: Date, lastSuccess: Date? = nil, lastFailure: Date? = nil,
                failures: Int = 0, meetingEnds: [Date] = []) {
        self.connected = connected
        self.launched = launched
        self.lastSuccess = lastSuccess
        self.lastFailure = lastFailure
        self.failures = failures
        self.meetingEnds = meetingEnds
    }

    /// When the next sync is due (it may be past); nil without a login.
    public var nextSync: Date? {
        guard connected else { return nil }
        if failures > 0, let lastFailure {
            return lastFailure.addingTimeInterval(Self.backoff[min(failures, Self.backoff.count) - 1])
        }
        var due: [Date] = []
        if let lastSuccess { due.append(lastSuccess.addingTimeInterval(Self.interval)) }
        if lastSuccess.map({ $0 < launched }) ?? true { due.append(launched.addingTimeInterval(Self.launchDelay)) }
        for end in meetingEnds {
            for wait in Self.afterMeeting {
                let at = end.addingTimeInterval(wait)
                if lastSuccess.map({ $0 < at }) ?? true { due.append(at) }
            }
        }
        return due.min()
    }

    /// Whether to sync now. The timer and a wake go by `nextSync`; Ask Tara opening also syncs a
    /// sync older than `askFreshness`, unless a failure is still waiting out its backoff.
    public func shouldSync(_ trigger: Trigger, now: Date) -> Bool {
        guard let next = nextSync else { return false }
        if next <= now { return true }
        guard trigger == .askOpened, failures == 0 else { return false }
        return lastSuccess.map { now.timeIntervalSince($0) > Self.askFreshness } ?? true
    }

    /// A sync finished well.
    public mutating func succeeded(at date: Date) {
        lastSuccess = date
        lastFailure = nil
        failures = 0
    }

    /// A sync failed: the next try waits out the backoff.
    public mutating func failed(at date: Date) {
        lastFailure = date
        failures += 1
    }
}
