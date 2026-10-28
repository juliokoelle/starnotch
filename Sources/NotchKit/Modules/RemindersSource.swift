import AppKit
import EventKit
import NotchCore

/// Apple Reminders as a Today source (optional, Settings › Modules): open reminders due today or
/// overdue. Asked for access only when the user switches it on. Cached; EventKit's change
/// notification refreshes it, so `today(now:)` stays instant.
final class RemindersSource: NotchConnector, TodayCompleting, @unchecked Sendable {
    static let id = "reminders"
    static let displayName = "Reminders"

    /// The user's switch.
    var enabled: () -> Bool = { false }
    /// A connector's Today, with the reminders added to its list (asked each time: a notes
    /// folder picked in Settings counts at once).
    var base: () -> (any TodayProvider)? = { nil }
    private let store = EKEventStore()
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
            lock.withLock { cached = [] }
            return
        }
        let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: end, calendars: nil)
        store.fetchReminders(matching: predicate) { [weak self] reminders in
            let items = (reminders ?? [])
                .sorted { ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture) }
                .prefix(8)
                .map { reminder -> TodayItem in
                    let due = reminder.dueDateComponents?.date.map { AgentScanner.day($0) }
                    return TodayItem(id: "reminder-" + reminder.calendarItemIdentifier, kind: .task, title: reminder.title ?? "Reminder",
                                     detail: reminder.calendar.title, date: due,
                                     url: URL(string: "x-apple-reminderkit://REMCDReminder/\(reminder.calendarItemIdentifier)"),
                                     help: "Open in Reminders", group: reminder.calendar.title,
                                     notes: reminder.notes.map { [$0] } ?? [])
                }
            self?.lock.withLock { self?.cached = Array(items) }
        }
    }

    func today(now: Date) -> TodayFeed {
        refresh()
        let reminders = lock.withLock { cached }
        guard var feed = base()?.today(now: now) else {
            return TodayFeed(now: reminders, nowTitle: "Reminders", emptyText: "No reminders due today.")
        }
        feed.now += reminders.filter { reminder in !feed.now.contains { $0.title == reminder.title } }
        return feed
    }

    /// The connector's tasks tick off where they live; reminders open in Reminders.
    func canComplete(_ id: String) -> Bool { (base() as? any TodayCompleting)?.canComplete(id) ?? false }
    func complete(_ id: String) -> Bool { (base() as? any TodayCompleting)?.complete(id) ?? false }
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
