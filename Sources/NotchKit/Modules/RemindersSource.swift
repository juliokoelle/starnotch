import AppKit
import EventKit
import NotchCore

/// Apple Reminders as a Today source (optional, Settings › Modules): open reminders, those due
/// today or overdue in Today's list, the rest (later or without a date) below it. Asked for access only when the user switches it on. Cached; EventKit's change
/// notification refreshes it, so `today(now:)` stays instant, and `onChange` tells Today when the
/// list came out different. The store is used on one queue.
final class RemindersSource: NotchConnector, TodayCompleting, @unchecked Sendable {
    static let id = "reminders"
    static let displayName = "Reminders"

    /// The user's switch.
    var enabled: () -> Bool = { false }
    /// A connector's Today, with the reminders added to its list (asked each time: a notes
    /// folder picked in Settings counts at once).
    var base: () -> (any TodayProvider)? = { nil }
    /// The reminders changed (fetched for the first time, after access was given, edited in
    /// Reminders): on the main thread, only when the list differs.
    var onChange: (@MainActor () -> Void)?
    private let store = EKEventStore()
    private let queue = DispatchQueue(label: "starnotch.reminders")
    private let lock = NSLock()
    private var cached: [TodayItem] = []
    private var observer: NSObjectProtocol?

    init(config: ConfigSection) {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }

    convenience init() { self.init(config: ConfigSection()) }

    static var authorized: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }

    /// Called on the user's click: macOS asks once.
    static func requestAccess(_ done: @escaping @Sendable (Bool) -> Void) {
        guard EKEventStore.authorizationStatus(for: .reminder) == .notDetermined else { done(authorized); return }
        EKEventStore().requestFullAccessToReminders { granted, _ in done(granted) }
    }

    func refresh() {
        guard enabled(), Self.authorized else {
            update([])
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
            store.fetchReminders(matching: predicate) { [weak self] reminders in
                let items = (reminders ?? [])
                    .sorted { ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture) }
                    .prefix(40)
                    .map { reminder -> TodayItem in
                        let due = reminder.dueDateComponents?.date.map { AgentScanner.day($0) }
                        return TodayItem(id: Self.prefix + reminder.calendarItemIdentifier, kind: .task, title: reminder.title ?? "Reminder",
                                         detail: reminder.calendar.title, date: due,
                                         url: URL(string: "x-apple-reminderkit://REMCDReminder/\(reminder.calendarItemIdentifier)"),
                                         help: "Open in Reminders", group: reminder.calendar.title,
                                         notes: reminder.notes.map { [$0] } ?? [])
                    }
                self?.update(Array(items))
            }
        }
    }

    /// Keeps the list; tells Today when it changed.
    private func update(_ items: [TodayItem]) {
        let changed = lock.withLock {
            guard cached != items else { return false }
            cached = items
            return true
        }
        guard changed else { return }
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.onChange?() } }
    }

    func today(now: Date) -> TodayFeed {
        refresh()
        let reminders = lock.withLock { cached }
        let day = AgentScanner.day(now)
        let isDue = { (item: TodayItem) in item.date.map { String($0.prefix(10)) <= day } ?? false }
        guard var feed = base()?.today(now: now) else {
            var feed = TodayFeed(now: reminders.filter(isDue), nowTitle: "Reminders", emptyText: "No reminders due today.")
            feed.later = reminders.filter { !isDue($0) }
            return feed
        }
        let mine = reminders.filter { reminder in !feed.now.contains { $0.title == reminder.title } }
        let due = mine.filter(isDue)
        feed.later += mine.filter { !isDue($0) }
        // The connector filled its main list with what comes later (nothing of its own is due):
        // with reminders due now, those move down to their own section.
        if !due.isEmpty, feed.followUps.isEmpty, !feed.now.isEmpty, feed.now.allSatisfy({ ($0.date ?? "") > day }) {
            feed.followUps = feed.now
            feed.followUpTitle = feed.nowTitle
            feed.now = []
            feed.nowTitle = Localization.string("Due today")
        }
        feed.now += due
        return feed
    }

    /// The connector's tasks and the reminders tick off where they live.
    func canComplete(_ id: String) -> Bool {
        if id.hasPrefix(Self.prefix) { return Self.authorized }
        return (base() as? any TodayCompleting)?.canComplete(id) ?? false
    }

    func complete(_ id: String) -> TodayCompletion {
        guard id.hasPrefix(Self.prefix) else { return (base() as? any TodayCompleting)?.complete(id) ?? .changed }
        guard Self.authorized else { return .failed }
        let result: TodayCompletion = queue.sync {
            guard let reminder = store.calendarItem(withIdentifier: String(id.dropFirst(Self.prefix.count))) as? EKReminder,
                  !reminder.isCompleted else { return .changed }
            reminder.isCompleted = true
            do { try store.save(reminder, commit: true) } catch { return .failed }
            return .done
        }
        // Gone from the list at once; EventKit's change notice refreshes the rest.
        if result == .done { lock.withLock { cached.removeAll { $0.id == id } } }
        return result
    }

    private static let prefix = "reminder-"
}

/// Writes one event from quick capture.
enum CalendarWriter {
    /// nil on success, else why not.
    static func add(title: String, start: Date, minutes: Int = 60) async -> String? {
        let store = EKEventStore()
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .notDetermined {
            guard (try? await store.requestWriteOnlyAccessToEvents()) == true else { return "calendar access not allowed" }
        } else if status != .fullAccess && status != .writeOnly {
            return "calendar access is off"
        }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = start.addingTimeInterval(Double(minutes) * 60)
        event.calendar = store.defaultCalendarForNewEvents
        guard event.calendar != nil else { return "no calendar to add to" }
        do { try store.save(event, span: .thisEvent) } catch { return error.localizedDescription }
        return nil
    }
}
