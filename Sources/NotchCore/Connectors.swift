import Foundation

// The connector API: how a data source plugs into the notch without the app knowing it.
//
// A connector is a class with a stable `id` and an initializer that takes its table from
// `config.toml` (`[connectors.<id>]`). It adopts any of the capability protocols below; the app
// asks the first connector that offers a capability. Connectors live in their own Swift package
// and are linked into a build by passing their types to `NotchApp.main(connectors:)`.
// See docs/SDK.md for a walkthrough.

/// A data source for the notch.
public protocol NotchConnector: AnyObject, Sendable {
    /// Stable identifier, also the config table name: `[connectors.<id>]`.
    static var id: String { get }
    /// Display name for Settings.
    static var displayName: String { get }
    init(config: ConfigSection)
    /// False while the user hasn't set it up yet: the app then treats its capabilities as missing.
    var isConfigured: Bool { get }
}

extension NotchConnector {
    public static var displayName: String { id }
    public var isConfigured: Bool { true }
}

// MARK: Today

/// A list for the Today module: what's on now, follow-ups, confirmations, a brief, counters.
public protocol TodayProvider: NotchConnector {
    /// Called on the main thread when the panel opens; keep it fast (cache, read small files).
    func today(now: Date) -> TodayFeed
}

public struct TodayItem: Equatable, Sendable, Identifiable {
    public enum Kind: Int, Sendable { case task, followUp, confirm }
    public var id: String
    public var kind: Kind
    public var title: String
    public var detail: String
    /// `YYYY-MM-DD`, if dated.
    public var date: String?
    /// Names of people the item mentions (follow-ups show the first as initials).
    public var people: [String]
    /// Where a click goes.
    public var url: URL?
    /// Tooltip of the row, e.g. "Open in Reminders".
    public var help: String
    /// Where it sits in the source, e.g. "Jetzt" (shown in the detail card).
    public var group: String
    /// More text for the detail card: notes, the raw line.
    public var notes: [String]

    public init(id: String, kind: Kind, title: String, detail: String = "", date: String? = nil,
                people: [String] = [], url: URL? = nil, help: String = "", group: String = "", notes: [String] = []) {
        self.group = group
        self.notes = notes
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.date = date
        self.people = people
        self.url = url
        self.help = help
    }
}

public struct TodayLink: Equatable, Sendable {
    public var title: String
    public var detail: String
    public var url: URL

    public init(title: String, detail: String = "", url: URL) {
        self.title = title
        self.detail = detail
        self.url = url
    }
}

public struct TodayCounter: Equatable, Sendable {
    public var label: String
    public var value: Int
    public var help: String
    public var url: URL?

    public init(label: String, value: Int, help: String = "", url: URL? = nil) {
        self.label = label
        self.value = value
        self.help = help
        self.url = url
    }
}

public struct TodayBrief: Equatable, Sendable {
    public var title: String
    /// Small time beside the title, e.g. "06:45".
    public var time: String
    public var text: String
    /// The briefing itself as Markdown, shown in full instead of `text`; empty when the note has
    /// no briefing yet. Nil for a source without one (then `text` shows).
    public var markdown: String?
    /// Where the briefing lives (opened from the card's title).
    public var url: URL?

    public init(title: String, time: String = "", text: String, markdown: String? = nil, url: URL? = nil) {
        self.title = title
        self.time = time
        self.text = text
        self.markdown = markdown
        self.url = url
    }
}

public struct TodayFeed: Equatable, Sendable {
    /// The main list ("Now"), soonest first.
    public var now: [TodayItem]
    public var followUps: [TodayItem]
    public var confirmations: [TodayItem]
    public var brief: TodayBrief?
    /// Small numbers in the footer, e.g. "Inbox 2".
    public var counters: [TodayCounter]
    /// The source's own home (the footer link), e.g. a web app.
    public var home: TodayLink?
    /// Shown in place of confirmations when there are none to show inline.
    public var confirmationsLink: TodayLink?
    /// Section titles and the empty line, so a connector can speak its own words.
    public var nowTitle: String
    public var followUpTitle: String
    public var confirmTitle: String
    public var emptyText: String
    /// Open tasks that aren't due yet or have no date (Apple Reminders): Today lists them under
    /// its due ones.
    public var later: [TodayItem] = []

    public init(now: [TodayItem] = [], followUps: [TodayItem] = [], confirmations: [TodayItem] = [],
                brief: TodayBrief? = nil, counters: [TodayCounter] = [], home: TodayLink? = nil,
                confirmationsLink: TodayLink? = nil, nowTitle: String = "Now", followUpTitle: String = "Follow up",
                confirmTitle: String = "Confirm", emptyText: String = "All done.") {
        self.now = now
        self.followUps = followUps
        self.confirmations = confirmations
        self.brief = brief
        self.counters = counters
        self.home = home
        self.confirmationsLink = confirmationsLink
        self.nowTitle = nowTitle
        self.followUpTitle = followUpTitle
        self.confirmTitle = confirmTitle
        self.emptyText = emptyText
    }
}

// MARK: Loops

/// Recurring jobs (agents on a schedule, cron jobs) with their last runs and next run.
public protocol JobsProvider: NotchConnector {
    /// Called off the main thread on every agent scan (every few seconds while the panel is
    /// open). Cache by modification time; a scan that finds nothing new should be cheap.
    func loops(now: Date) -> [LoopStatus]
    /// "Open the log" for a failed run.
    var logURL: URL? { get }
    /// Label of the link to a loop's `specURL`.
    var specLinkTitle: String { get }
}

extension JobsProvider {
    public var logURL: URL? { nil }
    public var specLinkTitle: String { "Open spec" }
}

// MARK: People

/// People for quick capture (names to recognise) and meeting prep (who's in the meeting, what's
/// open with them).
public protocol PeopleProvider: NotchConnector {
    func people() -> [Person]
    func prep(attendees: [String], now: Date) -> MeetingPrep
    /// Where "Open note" goes for a person.
    func noteURL(for person: PersonNote) -> URL?
    /// Heading of the prep card, e.g. "Prep".
    var prepTitle: String { get }
}

extension PeopleProvider {
    public func noteURL(for person: PersonNote) -> URL? { nil }
    public var prepTitle: String { "Prep" }
}

// MARK: Inbox

/// One quick capture.
public struct Capture: Equatable, Sendable {
    public enum Route: String, Sendable, CaseIterable { case task, question, note }
    public var text: String
    public var route: Route
    /// `YYYY-MM-DD` or `YYYY-MM-DD HH:MM`.
    public var due: String?
    /// People the parser recognised.
    public var people: [Person]
    public var created: Date

    public init(text: String, route: Route, due: String? = nil, people: [Person] = [], created: Date = Date()) {
        self.text = text
        self.route = route
        self.due = due
        self.people = people
        self.created = created
    }
}

public enum CaptureOutcome: Equatable, Sendable {
    /// Arrived where it should go.
    case delivered
    /// Kept locally; `reason` says why it isn't delivered yet.
    case queued(reason: String)
}

/// Where quick captures go. A sink must never lose a capture: keep a local copy when the
/// destination can't be reached.
public protocol InboxSink: NotchConnector {
    func file(_ capture: Capture) async -> CaptureOutcome
}

// MARK: Ticking off

/// What ticking a task off came to.
public enum TodayCompletion: Equatable, Sendable {
    case done
    /// The task changed where it lives (edited, moved twice, ticked off already): nothing was written.
    case changed
    /// Its place couldn't be read or written (file missing, not downloaded, no permission).
    case failed
}

/// A Today source whose tasks can be ticked off in the notch.
public protocol TodayCompleting: TodayProvider {
    /// Whether the item with this id gets a checkbox.
    func canComplete(_ id: String) -> Bool
    /// Marks it done where it lives. Called off the main thread. Anything but `.done` means
    /// nothing was written: return `.changed` rather than guess.
    func complete(_ id: String) -> TodayCompletion
}
