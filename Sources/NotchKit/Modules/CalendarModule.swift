import AppKit
import EventKit
import NotchCore
import Observation
import SwiftUI

/// The next meeting: countdown, a Join button for Meet, Zoom and Teams links, a sneak peek five
/// minutes before, and ⌃⌥J to join from anywhere.
///
/// Calendar access is requested the first time the module is shown, never at launch. Google
/// calendars appear when the account is added to macOS Calendar.
@MainActor
@Observable
final class CalendarModule: NotchModule {
    struct Meeting: Equatable, Identifiable {
        var id: String
        var title: String
        var start: Date
        var end: Date
        var calendar: String
        var color: Color
        var link: MeetingLink?
        var location: String? = nil
        var kind: EventKind = .meeting
        /// Names of the other people invited.
        var attendees: [String] = []

        /// Camera only for calls; a pin when there's a place; else the calendar.
        var symbol: String {
            if kind == .call { return "video.fill" }
            if let location, !location.isEmpty { return "mappin.and.ellipse" }
            return "calendar"
        }
    }

    enum Access: Equatable { case unknown, granted, denied }

    let kind = ModuleKind.calendar
    let symbol = ModuleSymbols.symbol(.calendar)

    private(set) var upcoming: [Meeting] = []
    /// All of today's timed events (also past ones), for the agenda.
    private(set) var today: [Meeting] = []
    /// Events per day this week, Monday first.
    private(set) var week: [Int] = Array(repeating: 0, count: 7)
    private(set) var access: Access = .unknown
    /// Sneak peeks go through the shell.
    @ObservationIgnored var onReminder: ((Meeting) -> Void)?

    @ObservationIgnored private let mock: Bool
    /// Seconds until the first sample meeting.
    @ObservationIgnored private let mockLead: TimeInterval
    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var reminded = Set<String>()
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var observer: NSObjectProtocol?

    init(mock: Bool, mockLead: TimeInterval = 5 * 60 + 8) {
        self.mock = mock
        self.mockLead = mockLead
        if mock {
            access = .granted
        } else {
            access = Self.currentAccess()
        }
    }

    static func currentAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .unknown
        default: .denied
        }
    }

    func start() {
        if mock { loadMock() }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                self?.reload()
            }
        }
    }

    /// Called when the module's view appears: the only place that may show the system dialog.
    func requestAccessIfNeeded() {
        // Ask only when macOS has never asked: never when access is granted or was declined.
        guard !mock else { return }
        access = Self.currentAccess()
        guard access == .unknown, EKEventStore.authorizationStatus(for: .event) == .notDetermined else {
            if access == .granted { reload() }
            return
        }
        store.requestFullAccessToEvents { [weak self] granted, _ in
            Task { @MainActor in
                self?.access = granted ? .granted : .denied
                self?.reload()
            }
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    private func reload() {
        if !mock {
            access = Self.currentAccess()
            if access == .granted {
                upcoming = fetch()
                let start = Calendar.current.startOfDay(for: Date())
                today = events(from: start, to: start.addingTimeInterval(86_400))
                let weekday = (Calendar.current.component(.weekday, from: start) + 5) % 7
                let monday = start.addingTimeInterval(-Double(weekday) * 86_400)
                let all = events(from: monday, to: monday.addingTimeInterval(7 * 86_400))
                week = (0..<7).map { day in
                    let from = monday.addingTimeInterval(Double(day) * 86_400)
                    return all.filter { $0.kind != .focus && $0.start >= from && $0.start < from.addingTimeInterval(86_400) }.count
                }
            }
        }
        checkReminder()
    }

    private func fetch(now: Date = Date()) -> [Meeting] {
        Array(events(from: now.addingTimeInterval(-60 * 60), to: now.addingTimeInterval(24 * 3600))
            .filter { $0.end > now }
            .prefix(4))
    }

    /// Timed events in a range, without cancelled or declined ones, classified call / meeting /
    /// focus block.
    private func events(from start: Date, to end: Date) -> [Meeting] {
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { event in
                !event.isAllDay && event.status != .canceled
                    && event.attendees?.first(where: \.isCurrentUser)?.participantStatus != .declined
            }
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                let link = MeetingLink.find(in: [event.url?.absoluteString, event.location, event.notes])
                let others = event.attendees?.filter { !$0.isCurrentUser } ?? []
                return Meeting(
                    id: event.eventIdentifier ?? UUID().uuidString,
                    title: event.title ?? "Event",
                    start: event.startDate,
                    end: event.endDate,
                    calendar: event.calendar.title,
                    color: Color(nsColor: event.calendar.color ?? .systemBlue),
                    link: link,
                    // A link-looking location ("https://meet…") is not a place.
                    location: event.location.flatMap { $0.contains("://") ? nil : $0 },
                    kind: EventKind.classify(hasCallLink: link != nil, otherAttendees: others.count),
                    attendees: others.compactMap { $0.name }
                )
            }
    }

    private func loadMock(now: Date = Date()) {
        // Sample data for screenshots: no EventKit, no permission dialog.
        upcoming = [
            Meeting(id: "mock-1", title: "Standup", start: now.addingTimeInterval(mockLead), end: now.addingTimeInterval(mockLead + 15 * 60),
                    calendar: "Work", color: Theme.accent,
                    link: MeetingLink(provider: .meet, url: URL(string: "https://meet.google.com/abc-defg-hij")!), kind: .call),
            Meeting(id: "mock-2", title: "Design review", start: now.addingTimeInterval(2 * 3600), end: now.addingTimeInterval(3 * 3600),
                    calendar: "Work", color: Theme.accent,
                    link: MeetingLink(provider: .zoom, url: URL(string: "https://zoom.us/j/123456789")!), kind: .call),
            Meeting(id: "mock-3", title: "Gym", start: now.addingTimeInterval(5 * 3600), end: now.addingTimeInterval(6 * 3600),
                    calendar: "Personal", color: Theme.ok, link: nil, kind: .focus),
        ]
    }

    private func checkReminder(now: Date = Date()) {
        guard let next = nextAttention, next.kind.remindsAndJoins, MeetingTime.isReminderDue(start: next.start, now: now), !reminded.contains(next.id) else { return }
        reminded.insert(next.id)
        onReminder?(next)
    }

    /// Recordings: the five-minute reminder right now.
    func demoReminder() {
        guard let next = nextAttention, next.kind.remindsAndJoins else { return }
        reminded.insert(next.id)
        onReminder?(next)
    }

    /// The meeting now running or coming up next.
    var next: Meeting? {
        let now = Date()
        return upcoming.first { $0.end > now }
    }

    /// The next event that may take the notch's attention (calls and meetings, no focus blocks).
    var nextAttention: Meeting? {
        let now = Date()
        return upcoming.first { $0.end > now && $0.kind.takesAttention }
    }

    func join() {
        guard let url = nextAttention?.link?.url else { return }
        Haptics.confirm()
        NSWorkspace.shared.open(url)
    }

    // MARK: NotchModule

    /// Beside the notch from ten minutes before until the meeting ends.
    var ambientPriority: Int {
        guard let next = nextAttention else { return 0 }
        let until = next.start.timeIntervalSinceNow
        return until <= 10 * 60 && next.end > Date() ? 30 : 0
    }

    var count: Int? { nil }

    /// The 5-minute reminder window.
    var needsAttention: Bool {
        guard let next = nextAttention else { return false }
        return next.start.timeIntervalSinceNow <= 5 * 60 && next.end > Date()
    }

    var bodyHeight: CGFloat {
        access == .granted ? CGFloat(96 + max(0, min(upcoming.count, 3) - 1) * 25) : 110
    }

    func leadingEar(peek: Bool) -> AnyView {
        AnyView(Image(systemName: nextAttention?.symbol ?? "calendar")
            .font(.system(size: peek ? 13 : 12, weight: .semibold))
            .foregroundStyle(nextAttention?.color ?? Theme.accent))
    }

    func trailingEar(peek: Bool) -> AnyView {
        AnyView(TimelineView(.periodic(from: .now, by: 1)) { context in
            if let next = self.nextAttention {
                Text(Self.short(next, now: context.date))
                    .font(Theme.font(peek ? 13 : 12, .semibold).monospacedDigit())
                    .foregroundStyle(Theme.accent)
                    .contentTransition(.numericText())
            }
        })
    }

    /// "5m", "now" for the ear.
    static func short(_ meeting: Meeting, now: Date) -> String {
        let seconds = meeting.start.timeIntervalSince(now)
        if seconds <= 0 { return "now" }
        return Durations.short(seconds < 3600 ? (seconds / 60).rounded(.up) * 60 : seconds)
    }

    func peekLine() -> AnyView {
        AnyView(TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                if let next = self.nextAttention ?? self.next {
                    let countdown = Text(MeetingTime.countdown(start: next.start, end: next.end, now: context.date))
                        .font(Theme.font(12.5).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                    Text(next.title).font(Theme.font(13, .semibold)).foregroundStyle(Theme.textPrimary)
                    ViewThatFits(in: .horizontal) { countdown.fixedSize(); Color.clear.frame(width: 0) }
                    Spacer(minLength: 6)
                    if let link = next.link {
                        JoinButton(link: link, compact: true) { self.join() }
                    }
                } else {
                    Text(self.access == .granted ? "No more meetings today" : "Next meeting")
                        .font(Theme.font(13, .medium)).foregroundStyle(Theme.textBody)
                    Spacer()
                }
            }
            .lineLimit(1)
        })
    }

    func body() -> AnyView { AnyView(CalendarBody(module: self)) }

    func primaryAction() { join() }
}

private struct CalendarBody: View {
    let module: CalendarModule

    var body: some View {
        NotchCard {
            switch module.access {
            case .granted:
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    content(now: context.date)
                }
            case .unknown, .denied:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Next meeting")
                        .font(Theme.font(14, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(module.access == .denied
                         ? "Calendar access is off. Turn it on in System Settings to see the next meeting and join with ⌃⌥J."
                         : "Allow calendar access to see the next meeting here and join with ⌃⌥J.")
                        .font(Theme.font(12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if module.access == .denied {
                        Button("Open Privacy Settings") { module.openPrivacySettings() }
                            .buttonStyle(PressScale())
                            .font(Theme.font(12, .medium))
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
        }
        .onAppear { module.requestAccessIfNeeded() }
    }

    @ViewBuilder private func content(now: Date) -> some View {
        if let next = module.next {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(next.color)
                        .frame(width: 4, height: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(next.title)
                            .font(Theme.font(15, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        HStack(spacing: 6) {
                            Text("\(TimeText.clock(next.start)) – \(TimeText.clock(next.end))")
                                .monospacedDigit()
                            Text("·")
                            Text(MeetingTime.countdown(start: next.start, end: next.end, now: now))
                                .foregroundStyle(next.start.timeIntervalSince(now) <= 5 * 60 ? Theme.accent : Theme.textSecondary)
                                .monospacedDigit()
                                .contentTransition(.numericText())
                            Text("·")
                            Text(next.calendar)
                        }
                        .font(Theme.font(12.5))
                        .foregroundStyle(Theme.textSecondary)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 8)
                    if let link = next.link {
                        VStack(alignment: .trailing, spacing: 4) {
                            JoinButton(link: link, compact: false) { module.join() }
                            Text("⌃⌥J").font(Theme.font(11.5)).foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
                let later = module.upcoming.filter { $0.id != next.id && $0.end > now }.prefix(2)
                if !later.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(later)) { meeting in
                            HStack(spacing: 8) {
                                Circle().fill(meeting.color).frame(width: 6, height: 6)
                                Text(TimeText.clock(meeting.start)).monospacedDigit().foregroundStyle(Theme.textSecondary)
                                Text(meeting.title).foregroundStyle(Theme.textBody)
                                if let link = meeting.link {
                                    Text(link.provider.rawValue).foregroundStyle(Theme.textTertiary)
                                }
                            }
                            .font(Theme.font(12.5))
                            .lineLimit(1)
                        }
                    }
                    .padding(.leading, 16)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("No more meetings today")
                    .font(Theme.font(14, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Meetings with a Meet, Zoom or Teams link get a Join button and ⌃⌥J.")
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

/// The one action of a meeting, in the accent.
struct JoinButton: View {
    let link: MeetingLink
    let compact: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "video.fill").font(.system(size: compact ? 10 : 11, weight: .semibold))
                Text("Join")
            }
            .font(Theme.font(compact ? 12 : 13, .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 9 : 12)
            .frame(height: compact ? 24 : 30)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: compact ? 8 : 9, style: .continuous))
        }
        .buttonStyle(PressScale())
        .help("Join with \(link.provider.rawValue) (⌃⌥J)")
    }
}
