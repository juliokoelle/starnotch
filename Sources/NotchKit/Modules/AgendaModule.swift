import AppKit
import NotchCore
import Observation
import SwiftUI

/// The calendar: the day, the next meeting and, with a `PeopleProvider` connector, what is known
/// about the people in it. Variant A puts the day on a horizontal time band; variant B is an agenda with a
/// briefing for the selected meeting.
@MainActor
@Observable
final class AgendaModule: NotchModule {
    enum Variant { case a, b }

    let kind = ModuleKind.calendar
    let symbol = "calendar"
    var variant: Variant
    /// Meeting prep (people, open items); without it the briefing lists the attendees.
    let people: (any PeopleProvider)?
    /// Live: EventKit through `CalendarModule`; `nil` for the recordings (mock day).
    let source: CalendarModule?
    /// Previews and the test mode: the made-up day (a recording may swap it).
    var mockEvents: [CalEvent]
    /// Keyboard and click selection; `nil` follows the next meeting.
    var selectedID: String?
    /// The user closed the detail side: the panel stays compact until they pick an event.
    var detailDismissed = false
    /// The day on show: 0 today, -1 yesterday, 1 tomorrow (⌘← ⌘→, the week strip, the arrows).
    private(set) var dayOffset = 0
    /// The events of that day when it isn't today.
    private var otherDay: [CalEvent] = []
    /// Day, week or month on show.
    enum Span: String, CaseIterable { case day = "Day", week = "Week", month = "Month" }
    private(set) var span = Span.day
    /// The week's or month's events.
    private(set) var rangeEvents: [CalEvent] = []
    /// Check camera beside Join (Settings › Tools); off, the button and the palette item go.
    var cameraCheckOn = true {
        didSet { if !cameraCheckOn { closeCamera() } }
    }
    /// Which meeting's card shows the camera check; the camera runs exactly while its preview does.
    private(set) var camera = CameraCheck() {
        didSet {
            guard camera.cameraOn != oldValue.cameraOn else { return }
            if camera.cameraOn { mirror.start() } else { mirror.stop() }
        }
    }
    let mirror = CameraMirror()
    /// Time to leave for today's events with a place (set by the app; Settings › Tools).
    var leave: LeaveTimes?
    /// Held while macOS asks for the camera, so the island is still open for the answer.
    @ObservationIgnored private var askLock: Int?

    init(variant: Variant, people: (any PeopleProvider)?, source: CalendarModule? = nil) {
        self.variant = variant
        self.people = people
        self.source = source
        mockEvents = source == nil ? AgendaSamples.day(R5Clock.now()) : []
        // The made-up day gets a made-up camera: previews never ask for or show the real one.
        mirror.simulated = source == nil
    }

    /// Who is in the meeting and what is open with them.
    func prep(for event: CalEvent) -> MeetingPrep {
        people?.prep(attendees: event.attendees, now: now) ?? MeetingPrep(unknown: event.attendees)
    }

    /// Heading of the prep card.
    var prepTitle: String { people?.prepTitle ?? "Attendees" }

    private func noteURL(for event: CalEvent) -> URL? {
        prep(for: event).people.first.flatMap { people?.noteURL(for: $0) }
    }

    /// "Open note" shows when the connector has a note for someone in the meeting.
    func hasNote(for event: CalEvent) -> Bool { noteURL(for: event) != nil }

    /// Today's events: the ears, the peek line and the next meeting always look at today.
    var todayEvents: [CalEvent] { source.map { $0.today.map(CalEvent.init) } ?? mockEvents }

    /// The events of the day on show.
    var events: [CalEvent] { dayOffset == 0 ? todayEvents : otherDay }

    var isToday: Bool { dayOffset == 0 }

    /// The day on show as a date.
    var shownDate: Date {
        Calendar.current.date(byAdding: .day, value: dayOffset, to: Calendar.current.startOfDay(for: now)) ?? now
    }

    /// The days the week or month view shows: the week from Monday; the month's weeks, Monday first.
    var spanDays: [Date] {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        let anchor = shownDate
        switch span {
        case .day:
            return [anchor]
        case .week:
            let start = calendar.dateInterval(of: .weekOfYear, for: anchor)?.start ?? anchor
            return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        case .month:
            guard let month = calendar.dateInterval(of: .month, for: anchor),
                  let first = calendar.dateInterval(of: .weekOfYear, for: month.start)?.start else { return [anchor] }
            let lastDay = month.end.addingTimeInterval(-1)
            let last = calendar.dateInterval(of: .weekOfYear, for: lastDay)?.end ?? month.end
            var days: [Date] = []
            var day = first
            while day < last, days.count < 42 {
                days.append(day)
                day = calendar.date(byAdding: .day, value: 1, to: day) ?? last
            }
            return days
        }
    }

    func events(on day: Date) -> [CalEvent] {
        let start = Calendar.current.startOfDay(for: day)
        let end = start.addingTimeInterval(86_400)
        return rangeEvents.filter { $0.start >= start && $0.start < end }
    }

    /// Day, week or month; the range's events are read once per switch.
    func setSpan(_ next: Span) {
        guard next != span else { return }
        Haptics.tick()
        withAnimation(Theme.snappy) {
            span = next
            selectedID = nil
            loadRange()
        }
    }

    /// The arrows: a day, a week or a month back or ahead.
    func step(by direction: Int) {
        switch span {
        case .day:
            showDay(dayOffset + direction)
        case .week:
            showDay(dayOffset + 7 * direction)
        case .month:
            let target = Calendar.current.date(byAdding: .month, value: direction, to: shownDate) ?? shownDate
            let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: now), to: target).day ?? 0
            showDay(days)
        }
        loadRange()
    }

    /// A day in the week or month view opens it as a day.
    func open(day: Date) {
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: now),
                                                   to: Calendar.current.startOfDay(for: day)).day ?? 0
        withAnimation(Theme.snappy) { span = .day }
        showDay(days)
    }

    private func loadRange() {
        guard span != .day, let first = spanDays.first, let last = spanDays.last else { rangeEvents = []; return }
        let end = last.addingTimeInterval(86_400)
        rangeEvents = source?.meetings(from: first, to: end).map(CalEvent.init)
            ?? mockEvents.filter { $0.start >= first && $0.start < end }
    }

    /// Shows another day; 0 goes back to today. An event being typed goes along to that day.
    func showDay(_ offset: Int) {
        guard offset != dayOffset else { return }
        Haptics.tick()
        withAnimation(Theme.snappy) {
            eventDraft?.shift(days: offset - dayOffset, calendar: .current)
            otherDay = offset == 0 ? [] : (source?.meetings(dayOffset: offset).map(CalEvent.init) ?? [])
            dayOffset = offset
            selectedID = nil
            detailDismissed = offset != 0
        }
    }

    /// The clock the day's views draw with: the real time today; the start of a later day (all
    /// of it ahead) or the end of an earlier one (all of it past).
    func viewNow(_ now: Date) -> Date {
        guard dayOffset != 0 else { return now }
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: now)) ?? now
        return dayOffset > 0 ? start : start.addingTimeInterval(86_399)
    }

    /// What makes a day stand out in the week glance (mock only for now).
    var weekNotes: [Int: String] { source == nil ? AgendaSamples.weekNotes : [:] }

    var now: Date { R5Clock.now() }

    /// The next meeting (not a focus block) that hasn't ended.
    var nextMeeting: CalEvent? {
        let now = now
        return todayEvents.first { $0.kind == .meeting && $0.end > now }
    }

    var selected: CalEvent? {
        if let selectedID, let event = events.first(where: { $0.id == selectedID }) { return event }
        return detailDismissed || dayOffset != 0 ? nil : nextMeeting
    }

    /// A click on an event opens its detail; on the open one, closes it again.
    func select(_ event: CalEvent) {
        Haptics.tick()
        withAnimation(Theme.snappy) {
            if selected?.id == event.id {
                selectedID = nil
                detailDismissed = true
            } else {
                selectedID = event.id
                detailDismissed = false
            }
        }
    }

    /// The agenda's detail side shows (a meeting with prep is next, the user picked one, or a new
    /// event is being typed).
    var showsDetail: Bool { variant == .b && (selected != nil || eventDraft != nil) }

    /// Every event's lane on the day band (overlaps stack), by id.
    var lanes: [String: Int] {
        let list = events
        let assigned = DayLayout.lanes(list.map { (start: $0.startMinutes, end: $0.endMinutes) })
        return Dictionary(uniqueKeysWithValues: zip(list.map(\.id), assigned))
    }

    var laneCount: Int { max(1, (lanes.values.max() ?? 0) + 1) }

    /// Hours on the band: 08–22, widened to the day's events.
    var bandHours: (from: Double, to: Double) {
        DayLayout.hours(events.map { (start: $0.startMinutes, end: $0.endMinutes) })
    }

    /// "free until 09:30", "Opening talk until 10:30".
    func dayStatus(now: Date) -> String {
        DayLayout.status(events.map { (title: $0.title, start: $0.startMinutes, end: $0.endMinutes) }, now: R5Clock.minutes(now))
    }

    var meetingCount: Int { events.filter { $0.kind == .meeting }.count }
    var focusCount: Int { events.filter { $0.kind == .focus }.count }

    var weekCounts: [Int] {
        var counts = source?.week ?? AgendaSamples.week
        counts[todayIndex] = todayEvents.filter { $0.kind == .meeting }.count
        return counts
    }

    /// The day on show in the week strip, nil when it lies outside this week.
    var shownIndex: Int? {
        let index = todayIndex + dayOffset
        return (0..<7).contains(index) ? index : nil
    }

    var todayIndex: Int { (Calendar.current.component(.weekday, from: now) + 5) % 7 }

    /// Free time from now until the band's end that no event covers (focus blocks count: time
    /// in a block isn't free).
    func gaps(now: Date) -> [DayGaps.Gap] {
        let busy = events.map { (start: $0.startMinutes, end: $0.endMinutes) }
        let from = max(bandHours.from, R5Clock.minutes(now))
        return DayLayout.free(busy, from: from, to: bandHours.to, minimum: 40)
    }

    func open(_ event: CalEvent) {
        if let link = event.link {
            Haptics.confirm()
            // The call takes the camera over: the check ends with Join.
            closeCamera()
            NSWorkspace.shared.open(link.url)
        } else if let url = noteURL(for: event) {
            NSWorkspace.shared.open(url)
        }
    }

    func openNote(for event: CalEvent) {
        if let url = noteURL(for: event) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Check camera

    /// Today's call under way or next (a meeting with a call link): what a camera check is for.
    var nextCall: CalEvent? {
        let now = now
        return todayEvents.first { $0.kind == .meeting && $0.link != nil && $0.end > now }
    }

    /// Check camera on a meeting's card: the mirrored preview, macOS's dialog the first time,
    /// or, with access off, a note and System Settings › Privacy & Security › Camera.
    func checkCamera(_ event: CalEvent) {
        Haptics.tick()
        toggleCamera(event)
    }

    /// The command palette: the calendar on today's next call with its camera check open.
    func checkCameraBeforeNextCall() {
        guard let call = nextCall else { return }
        DailyStore.shared.cardShown = false
        withAnimation(Theme.snappy) {
            selectedID = call.id
            detailDismissed = false
        }
        if camera.meetingID != call.id { toggleCamera(call) }
    }

    func closeCamera() {
        releaseAskLock()
        guard camera.meetingID != nil || camera.asking != nil else { return }
        withAnimation(Theme.snappy) { camera.close() }
    }

    /// A meeting's card left (another one picked, another day, the tab or the panel closed).
    func cardLeft(_ event: CalEvent) {
        guard camera.meetingID == event.id || camera.asking == event.id else { return }
        if camera.asking == event.id { releaseAskLock() }
        camera.left(event.id)
    }

    private func toggleCamera(_ event: CalEvent) {
        // macOS's dialog is up already: another click asks nothing new.
        guard camera.asking != event.id else { return }
        let step = withAnimation(Theme.snappy) { camera.click(event.id, access: mirror.access) }
        switch step {
        case .ask:
            releaseAskLock()
            askLock = IslandLock.shared.acquire("camera access")
            mirror.requestAccess { [weak self] granted in
                guard let self else { return }
                self.releaseAskLock()
                withAnimation(Theme.snappy) { self.camera.answered(event.id, granted: granted) }
            }
        case .openSettings:
            PrivacyPane.open("Privacy_Camera")
        case .show, .close:
            break
        }
    }

    /// Previews: the note for camera access that is off, on today's next call (System Settings
    /// stays closed).
    func usePreviewCameraNote() {
        guard let call = nextCall else { return }
        selectedID = call.id
        detailDismissed = false
        _ = camera.click(call.id, access: .denied)
    }

    private func releaseAskLock() {
        guard let held = askLock else { return }
        askLock = nil
        IslandLock.shared.release(held)
    }

    // MARK: Adding an event

    /// Settings › Tools: the "+" in the header (on by default).
    @ObservationIgnored var editsAllowed: () -> Bool = { true }
    /// The event being typed after the "+"; nil while there is none.
    private(set) var eventDraft: EventDraft?
    private(set) var savingEvent = false
    /// Why the last one wasn't added, under the field.
    private(set) var eventError: String?

    var canAddEvents: Bool { variant == .b && editsAllowed() }

    /// Where a new event goes: the default calendar (the made-up "Work" in previews).
    var newEventCalendar: (title: String, color: Color)? {
        source.map { $0.defaultCalendar } ?? (CalendarSource.work.rawValue, CalendarSource.work.color)
    }

    /// The form takes the detail side of the day; from the week or the month it opens the day.
    func startEvent() {
        guard canAddEvents else { return }
        Haptics.tick()
        withAnimation(Theme.snappy) {
            if span != .day {
                span = .day
                rangeEvents = []
            }
            eventDraft = EventDraft(day: shownDate, now: now, calendar: .current)
            eventError = nil
        }
    }

    func cancelEvent(feel: Bool = true) {
        guard eventDraft != nil else { return }
        if feel { Haptics.tick() }
        withAnimation(Theme.snappy) {
            eventDraft = nil
            eventError = nil
        }
    }

    func updateEvent(text: String) {
        eventDraft?.update(text: text, now: now, calendar: .current)
        if eventError != nil { eventError = nil }
        followDraft()
    }

    func shiftEvent(days: Int) {
        Haptics.tick()
        withAnimation(Theme.snappy) { eventDraft?.shift(days: days, calendar: .current) }
        followDraft()
    }

    func shiftEvent(minutes: Int) {
        Haptics.tick()
        withAnimation(Theme.snappy) { eventDraft?.shift(minutes: minutes, calendar: .current) }
    }

    func nextEventLength() {
        Haptics.tick()
        withAnimation(Theme.snappy) { eventDraft?.nextLength() }
    }

    /// The day on show follows the event's day, so its neighbours are in view.
    private func followDraft() {
        guard let start = eventDraft?.start else { return }
        let calendar = Calendar.current
        let offset = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: start)).day ?? 0
        guard offset != dayOffset else { return }
        withAnimation(Theme.snappy) {
            otherDay = offset == 0 ? [] : (source?.meetings(dayOffset: offset).map(CalEvent.init) ?? [])
            dayOffset = offset
            selectedID = nil
        }
    }

    /// ↵: added to the default calendar off the main thread (macOS asks on the first save); the
    /// form closes once it's there. Previews and the test mode add it to the made-up day only.
    func saveEvent() {
        guard let draft = eventDraft, draft.canSave, !savingEvent else { return }
        savingEvent = true
        Haptics.confirm()
        let title = draft.title, start = draft.start, minutes = draft.minutes
        Task { [weak self] in
            guard let self else { return }
            var error: String?
            if let source = self.source {
                error = await CalendarWriter.add(title: title, start: start, minutes: minutes)
                if error == nil { source.reload() }
            } else {
                self.mockEvents.append(CalEvent(id: "added-\(self.mockEvents.count)", title: title, start: start, end: draft.end,
                                                calendar: .work, kind: .focus))
                self.mockEvents.sort { $0.start < $1.start }
            }
            self.savingEvent = false
            if let error {
                withAnimation(Theme.snappy) { self.eventError = error }
                return
            }
            withAnimation(Theme.snappy) {
                self.eventDraft = nil
                if self.dayOffset != 0 { self.otherDay = self.source?.meetings(dayOffset: self.dayOffset).map(CalEvent.init) ?? [] }
            }
        }
    }

    // MARK: NotchModule

    var ambientPriority: Int {
        guard let next = nextMeeting else { return 0 }
        return next.start.timeIntervalSince(now) <= 15 * 60 ? 30 : 0
    }

    var needsAttention: Bool {
        guard let next = nextMeeting, next.kind == .meeting else { return false }
        return next.start.timeIntervalSince(now) <= 5 * 60 && next.end > now
    }

    /// A picked event, or a form on show (here or in Today), keeps the panel open.
    var holdsOpen: Bool {
        let daily = DailyStore.shared
        return selectedID != nil || (daily.cardShown ? daily.today?.reminderDraft != nil : eventDraft != nil)
    }

    func handleBack() -> Bool {
        // Esc closes the camera check first, back to the briefing.
        if camera.meetingID != nil {
            closeCamera()
            return true
        }
        // Today is where the tab opens: Esc there closes the panel.
        guard !DailyStore.shared.cardShown, showsDetail else { return false }
        withAnimation(Theme.snappy) {
            selectedID = nil
            detailDismissed = true
        }
        return true
    }

    func setExpanded(_ expanded: Bool) {
        if expanded {
            // Today first; a meeting within the quarter hour keeps the calendar and its briefing.
            DailyStore.shared.cardShown = DailyStore.shared.opensOnToday && ambientPriority == 0
        } else {
            closeCamera()
            eventDraft = nil
            eventError = nil
            DailyStore.shared.today?.cancelReminder(feel: false)
            selectedID = nil
            detailDismissed = false
            dayOffset = 0
            otherDay = []
            span = .day
            rangeEvents = []
        }
    }

    func leadingEar(peek: Bool) -> AnyView {
        AnyView(TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = R5Clock.now(context.date)
            if let next = self.nextMeeting {
                switch self.variant {
                case .a:
                    // A small dot in the calendar's color; a camera only when there is a link.
                    HStack(spacing: 5) {
                        Circle().fill(next.calendar.color)
                            .frame(width: peek ? 8 : 7, height: peek ? 8 : 7)
                            .shadow(color: next.calendar.color.opacity(0.8), radius: 4)
                        if next.link != nil {
                            Image(systemName: "video.fill").font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                case .b:
                    CountdownRing(start: next.start, end: next.end, now: now, size: peek ? 16 : 14, color: next.calendar.color, showsLabel: false)
                }
            }
        })
    }

    func trailingEar(peek: Bool) -> AnyView {
        AnyView(TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = R5Clock.now(context.date)
            if let next = self.nextMeeting, peek {
                Text(R5Clock.countdown(start: next.start, end: next.end, now: now).replacingOccurrences(of: " left", with: ""))
                    .font(Theme.font(peek ? 12.5 : 12, .semibold).monospacedDigit())
                    .foregroundStyle(next.start.timeIntervalSince(now) <= 5 * 60 ? Theme.accent : Theme.textBody)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .fixedSize()
            } else if let next = self.nextMeeting {
                // The narrow compact ear: just the minutes.
                let seconds = next.start.timeIntervalSince(now)
                Text(seconds <= 0 ? "now" : Durations.short(seconds < 3600 ? (seconds / 60).rounded(.up) * 60 : seconds))
                    .font(Theme.font(11, .semibold).monospacedDigit())
                    .foregroundStyle(seconds <= 5 * 60 ? Theme.accent : Theme.textBody)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        })
    }

    func peekLine() -> AnyView {
        AnyView(TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = R5Clock.now(context.date)
            HStack(spacing: 8) {
                if let next = self.nextMeeting {
                    let title = Text(next.title).font(Theme.font(13, .semibold)).foregroundStyle(Theme.textPrimary)
                    let countdown = Text(R5Clock.countdown(start: next.start, end: next.end, now: now))
                        .font(Theme.font(12.5).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                    // Narrow peek: people and open items go first, then the countdown; the title truncates.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            if self.variant == .b { AvatarStack(names: next.attendees, size: 20) }
                            title.fixedSize()
                            countdown.fixedSize()
                            Spacer(minLength: 6)
                            if self.variant == .b {
                                let open = self.prep(for: next).items.count
                                if open > 0 {
                                    Text(open == 1 ? "1 open item" : "\(open) open items")
                                        .font(Theme.font(12)).foregroundStyle(Theme.waiting).fixedSize()
                                }
                            } else if let link = next.link {
                                JoinPill(link: link, key: "⌃⌥J") { self.open(next) }
                                    .scaleEffect(0.9)
                            }
                        }
                        HStack(spacing: 8) { title.fixedSize(); countdown.fixedSize(); Spacer(minLength: 0) }
                        HStack(spacing: 8) { title; Spacer(minLength: 0) }
                    }
                } else {
                    Text("No more meetings today").font(Theme.font(13, .medium)).foregroundStyle(Theme.textBody)
                    Spacer()
                }
            }
            .lineLimit(1)
        })
    }

    func body() -> AnyView {
        if let source, source.access != .granted {
            return AnyView(AgendaAccess(source: source))
        }
        switch variant {
        case .a: return AnyView(AgendaBodyA(module: self))
        case .b: return AnyView(AgendaBodyB(module: self))
        }
    }

    func primaryAction() {
        if let selected { open(selected) }
    }

    func handleKey(_ press: KeyPress) -> Bool {
        // A form has the keyboard: ↵ saves, esc cancels, and nothing else walks days or tabs meanwhile.
        if DailyStore.shared.cardShown, let today = DailyStore.shared.today, today.reminderDraft != nil {
            if press.key == .escape { today.cancelReminder() } else if press.key == .return { today.saveReminder() }
            return true
        }
        if !DailyStore.shared.cardShown, eventDraft != nil {
            if press.key == .escape { cancelEvent() } else if press.key == .return { saveEvent() }
            return true
        }
        switch press.key {
        case .upArrow, .downArrow:
            return step(press.key == .downArrow ? 1 : -1)
        case .leftArrow where press.modifiers.contains(.command), .rightArrow where press.modifiers.contains(.command):
            step(by: press.key == .rightArrow ? 1 : -1)
            return true
        default:
            switch press.characters {
            case "t" where dayOffset != 0: showDay(0); loadRange(); return true
            case "d": setSpan(.day); return true
            case "w": setSpan(.week); return true
            case "m": setSpan(.month); return true
            default: return false
            }
        }
    }

    /// Up and down: the previous or next event, focus blocks included.
    @discardableResult func step(_ delta: Int) -> Bool {
        let list = events
        guard !list.isEmpty else { return true }
        let index = list.firstIndex { $0.id == selected?.id } ?? 0
        let next = min(max(index + delta, 0), list.count - 1)
        if next != index { select(list[next]) }
        return true
    }
}

// MARK: Shared: the meeting and its preparation

/// Title, time, ring, people, place or provider, and Beitreten only with a link.
private struct MeetingCard: View {
    let module: AgendaModule
    let event: CalEvent
    let now: Date

    var body: some View {
        NotchCard(padding: 14) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    if event.kind == .meeting {
                        CountdownRing(start: event.start, end: event.end, now: now)
                    } else {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(event.calendar.color.opacity(0.12))
                            .overlay(Hatch(color: event.calendar.color.opacity(0.35)).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous)))
                            .frame(width: 46, height: 46)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.title)
                            .font(Theme.font(14.5, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 5) {
                            Circle().fill(event.calendar.color).frame(width: 6, height: 6)
                            Text("\(TimeText.clock(event.start))–\(TimeText.clock(event.end))").monospacedDigit()
                            Text("·")
                            Text(event.kind == .focus ? "Focus" : event.calendar.rawValue)
                        }
                        .font(Theme.font(12))
                        .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 10)
                if !event.attendees.isEmpty {
                    HStack(spacing: 8) {
                        AvatarStack(names: event.attendees, size: 22)
                        Text(event.attendees.map { $0.split(separator: " ").first.map(String.init) ?? $0 }.joined(separator: ", "))
                            .font(Theme.font(12)).foregroundStyle(Theme.textBody).lineLimit(1)
                    }
                } else {
                    Text(event.kind == .focus ? "Solo, no link. Doesn't count as busy." : "No attendees")
                        .font(Theme.font(12)).foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 10)
                HStack(spacing: 6) {
                    if let link = event.link {
                        Image(systemName: "video").font(.system(size: 10.5, weight: .medium))
                        Text(link.provider.displayName)
                    } else if let location = event.location {
                        Image(systemName: "mappin").font(.system(size: 10.5, weight: .medium))
                        Text(location)
                    }
                    Spacer(minLength: 6)
                    if let link = event.link, event.end > now {
                        JoinPill(link: link) { module.open(event) }
                    }
                }
                .font(Theme.font(12))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .frame(height: 26)
            }
        }
    }
}

/// What the connector knows: one line per person, open tasks and waiting items that mention them.
private struct PrepList: View {
    let module: AgendaModule
    let event: CalEvent
    var avatarSize: CGFloat = 26
    var maxPeople = 2
    var maxItems = 3
    /// Lines for the last-contact note (the briefing gives it room).
    var noteLines = 1

    var body: some View {
        let prep = module.prep(for: event)
        let today = R5Clock.day(module.now)
        VStack(alignment: .leading, spacing: 9) {
            if prep.people.isEmpty && prep.unknown.isEmpty {
                Text(event.kind == .focus ? "Focus block. No people, nothing to prepare." : "No attendees on this event.")
                    .font(Theme.font(12)).foregroundStyle(Theme.textTertiary)
            }
            ForEach(prep.people.prefix(maxPeople), id: \.slug) { person in
                HStack(alignment: .top, spacing: 9) {
                    InitialsAvatar(name: person.name, size: avatarSize)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(person.name).font(Theme.font(12.5, .semibold)).foregroundStyle(Theme.textPrimary)
                            Text(person.summary).font(Theme.font(11.5)).foregroundStyle(Theme.textSecondary)
                        }
                        if let last = person.lastContact {
                            Text("Last \(Self.shortDay(last.day)) · \(last.note)")
                                .font(Theme.font(11.5)).foregroundStyle(Theme.textTertiary)
                                .lineLimit(noteLines)
                                .fixedSize(horizontal: false, vertical: noteLines > 1)
                        }
                    }
                    .lineLimit(1)
                }
            }
            if prep.people.count > maxPeople {
                Text("+ \(prep.people.count - maxPeople) more with a note").font(Theme.font(11.5)).foregroundStyle(Theme.textTertiary)
            }
            ForEach(prep.unknown, id: \.self) { name in
                HStack(spacing: 9) {
                    InitialsAvatar(name: name, size: avatarSize)
                    Text(name).font(Theme.font(12.5, .semibold)).foregroundStyle(Theme.textPrimary)
                    if module.people != nil {
                        Text("no person note yet").font(Theme.font(11.5)).foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            if !prep.items.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(prep.items.prefix(maxItems).enumerated()), id: \.offset) { _, item in
                        let soon = item.date.map { R5Clock.isSoon($0, today: today) } ?? false
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Image(systemName: item.source == .task ? "circle" : "hourglass")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(soon ? Theme.waiting : Theme.textTertiary)
                                .frame(width: 12)
                            Text(item.source == .task ? "Task" : "Waiting")
                                .font(Theme.font(11)).foregroundStyle(Theme.textTertiary)
                            Text(item.title).font(Theme.font(12)).foregroundStyle(Theme.textBody)
                            Spacer(minLength: 4)
                            if let date = item.date {
                                Text(R5Clock.due(date, today: today))
                                    .font(Theme.font(11.5).monospacedDigit())
                                    .foregroundStyle(soon ? Theme.waiting : Theme.textSecondary)
                            }
                        }
                        .lineLimit(1)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    static func shortDay(_ day: String) -> String {
        let parts = day.prefix(10).split(separator: "-")
        return parts.count == 3 ? "\(parts[2]).\(parts[1])." : day
    }
}

// MARK: Variant A: the day on a time band

private struct AgendaBodyA: View {
    let module: AgendaModule

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = R5Clock.now(context.date)
            VStack(spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    Text(R5Clock.longDay(now)).font(Theme.font(13.5, .semibold)).foregroundStyle(Theme.textPrimary)
                    Text("\(module.meetingCount) meetings · \(module.focusCount) focus blocks")
                        .font(Theme.font(12)).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    WeekGlance(counts: module.weekCounts, today: module.todayIndex, notes: module.weekNotes, height: 13)
                }
                .padding(.horizontal, 6)
                .frame(height: 30)

                NotchCard(padding: 12) {
                    DayBand(module: module, now: now)
                }
                .frame(height: DayBand.height(lanes: module.laneCount) + 24)

                if let event = module.selected {
                    HStack(spacing: 10) {
                        MeetingCard(module: module, event: event, now: now)
                            .frame(width: 256)
                        NotchCard(padding: 14) {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(module.prepTitle).font(Theme.font(12, .semibold)).foregroundStyle(Theme.textSecondary)
                                    Spacer()
                                    if module.hasNote(for: event) {
                                        QuietLink(title: "Open note") { module.openNote(for: event) }
                                    }
                                }
                                PrepList(module: module, event: event, avatarSize: 24, maxPeople: 2, maxItems: 2)
                            }
                        }
                    }
                    .frame(height: 172)
                    .id(event.id)
                    .transition(.blurSlide(y: 6))
                }
            }
        }
    }
}

/// The day on one band: every event in its lane (overlaps stack instead of covering each
/// other), its title inside when it fits and on hover otherwise, the past dimmed, the now line in
/// the accent. The hours stretch to the day's first and last event; the height to its lanes.
struct DayBand: View {
    let module: AgendaModule
    let now: Date
    static let laneHeight: CGFloat = 20
    static let laneGap: CGFloat = 4
    static let labels: CGFloat = 16

    static func height(lanes: Int) -> CGFloat {
        CGFloat(lanes) * laneHeight + CGFloat(max(0, lanes - 1)) * laneGap + 6 + labels
    }

    var body: some View {
        let hours = module.bandHours
        let lanes = module.lanes
        let laneCount = module.laneCount
        let blocks = CGFloat(laneCount) * Self.laneHeight + CGFloat(laneCount - 1) * Self.laneGap
        GeometryReader { proxy in
            let width = proxy.size.width
            let nowMinutes = R5Clock.minutes(now)
            let x = { (m: Double) -> CGFloat in CGFloat((m - hours.from) / (hours.to - hours.from)) * width }
            let step = (hours.to - hours.from) / 60 > 16 ? 3 : 2
            ZStack(alignment: .topLeading) {
                // Hour ticks and labels.
                ForEach(Array(stride(from: Int(hours.from / 60), through: Int(hours.to / 60), by: step)), id: \.self) { hour in
                    let hx = x(Double(hour) * 60)
                    Rectangle().fill(Color.white.opacity(0.05)).frame(width: 1, height: blocks + 4).offset(x: hx, y: 0)
                    Text(String(format: "%02d", hour))
                        .font(Theme.font(10).monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize()
                        .offset(x: hx >= width - 8 ? hx - 12 : max(0, hx - 6), y: blocks + 6)
                }
                ForEach(module.events) { event in
                    let ex = x(event.startMinutes), ew = max(x(event.endMinutes) - ex - 2, 6)
                    let lane = CGFloat(lanes[event.id] ?? 0)
                    EventBlock(event: event, width: ew, selected: module.selected?.id == event.id, past: event.end <= now) {
                        module.select(event)
                    }
                    .offset(x: ex, y: lane * (Self.laneHeight + Self.laneGap))
                }
                // The past sits behind a veil.
                Rectangle()
                    .fill(Color.black.opacity(0.32))
                    .frame(width: max(0, min(width, x(nowMinutes))), height: blocks + 2)
                    .allowsHitTesting(false)
                // Now.
                if nowMinutes >= hours.from && nowMinutes <= hours.to {
                    ZStack(alignment: .top) {
                        Rectangle().fill(Theme.accent).frame(width: 1.5, height: blocks + 6)
                        Circle().fill(Theme.accent).frame(width: 6, height: 6).offset(y: -3)
                    }
                    .shadow(color: Theme.accent.opacity(0.9), radius: 4)
                    .offset(x: x(nowMinutes) - 0.75, y: -3)
                    .allowsHitTesting(false)
                }
            }
        }
        .frame(height: Self.height(lanes: laneCount))
    }
}

/// One event on the band: meetings filled, focus blocks hatched (quiet, clearly not a meeting).
/// The title shows inside only when it fits whole; the full line is always on hover.
private struct EventBlock: View {
    let event: CalEvent
    let width: CGFloat
    let selected: Bool
    let past: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        let color = event.calendar.color
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Button(action: action) {
            ZStack(alignment: .leading) {
                if event.kind == .meeting {
                    shape.fill(color.opacity(past ? 0.14 : hovered || selected ? 0.36 : 0.26))
                } else {
                    shape.fill(color.opacity(hovered || selected ? 0.14 : 0.07))
                    Hatch(color: color.opacity(past ? 0.12 : 0.22), spacing: 5).clipShape(shape)
                }
                shape.strokeBorder(Color.white.opacity(selected ? 0.5 : 0), lineWidth: 1)
                ViewThatFits(in: .horizontal) {
                    Text(event.title).fixedSize()
                    Color.clear.frame(width: 0)
                }
                .font(Theme.font(10.5, selected ? .semibold : .medium))
                .foregroundStyle(event.kind == .meeting
                                 ? (past ? Theme.textTertiary : Theme.textPrimary)
                                 : color.blended(with: .white, by: 0.35).opacity(past ? 0.5 : 0.95))
                .padding(.horizontal, 7)
                .frame(width: width, alignment: .leading)
            }
            .frame(width: width, height: DayBand.laneHeight)
            .clipShape(shape)
            .shadow(color: selected ? color.opacity(0.55) : .clear, radius: 8)
            .contentShape(shape)
        }
        .buttonStyle(PressScale())
        .onHover { hovered = $0 }
        .animation(Theme.snappy, value: hovered)
        .animation(Theme.snappy, value: selected)
        .help("\(event.title) · \(TimeText.clock(event.start))–\(TimeText.clock(event.end))")
    }
}

// MARK: Variant B: agenda with a briefing

private struct AgendaBodyB: View {
    let module: AgendaModule

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = module.viewNow(R5Clock.now(context.date))
            VStack(spacing: 8) {
                // Narrowing steps until the row fits the panel (it pushed the cards below past the
                // panel's edges): the short date and summary, no day chip, "D W M" for the spans,
                // last no week strip.
                ViewThatFits(in: .horizontal) {
                    header(now: now, clock: context.date, step: 0)
                    header(now: now, clock: context.date, step: 1)
                    header(now: now, clock: context.date, step: 2)
                    header(now: now, clock: context.date, step: 3)
                    header(now: now, clock: context.date, step: 4)
                }
                .padding(.horizontal, 6)
                .frame(height: 32)

                if module.span == .week {
                    WeekView(module: module, now: R5Clock.now(context.date))
                } else if module.span == .month {
                    MonthView(module: module, now: R5Clock.now(context.date))
                } else {
                NotchCard(padding: 8) {
                    DayBand(module: module, now: now)
                }
                .frame(height: DayBand.height(lanes: module.laneCount) + 16)

                HStack(alignment: .top, spacing: 10) {
                    NotchCard(padding: 10) {
                        // A full day scrolls inside the card. It opens on the now line (or the
                        // open event) and follows the selection when ↑↓ walk the list.
                        ScrollViewReader { proxy in
                            ScrollView(.vertical) {
                                AgendaList(module: module, now: now)
                            }
                            .scrollIndicators(.never)
                            .scrollEdgeFade(top: 12)
                            .onAppear { proxy.scrollTo(module.selected?.id ?? "now", anchor: .center) }
                            .onChange(of: module.selected?.id) { _, id in
                                guard let id else { return }
                                withAnimation(Theme.snappy) { proxy.scrollTo(id) }
                            }
                        }
                    }
                    .frame(width: module.showsDetail ? 256 : nil)

                    if module.eventDraft != nil {
                        EventComposer(module: module)
                            .transition(.blurSlide(x: 10))
                    } else if let event = module.selected {
                        Briefing(module: module, event: event, now: now)
                            .id(event.id)
                            .transition(.blurSlide(x: 10))
                    }
                }
                }
            }
        }
        // The day card (weather, work day, last night) over the agenda, from the chip.
        .overlay {
            if DailyStore.shared.cardShown {
                DailyCard(store: .shared)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(Color.black.padding(-8))
                    .transition(.blurSlide(y: -8))
            }
        }
        // Covered by the day card, the camera check is out of sight: it stops.
        .onChange(of: DailyStore.shared.cardShown) { _, shown in if shown { module.closeCamera() } }
        .onAppear { module.source?.requestAccessIfNeeded() }
    }

    /// The row above the day: the switch to Today, the date with its summary, the week strip.
    /// `step` 0 is the full row; each step narrows it (see the caller), 4 truncates the summary.
    /// The chip only repeats what Today shows, so it goes before the week strip.
    private func header(now: Date, clock: Date, step: Int) -> some View {
        HStack(alignment: .center, spacing: 10) {
            // The switch to Today, where Today has the same one.
            CalendarTodaySwitch(store: .shared)
            VStack(alignment: .leading, spacing: 1) {
                DayHeader(module: module, now: now, short: step > 0, shortSpans: step > 2)
                if module.span == .day {
                    // Weather, the day's progress and last night beside the summary, when those
                    // tools are on (Today has them in full).
                    HStack(spacing: 8) {
                        if step < 4 {
                            Text(summary(now, short: step > 0)).fixedSize()
                        } else {
                            Text(summary(now, short: true))
                        }
                        if module.isToday, step < 2 { DailyChip(store: .shared) }
                    }
                    .font(Theme.font(11.5)).foregroundStyle(Theme.textSecondary)
                } else {
                    Text(module.rangeEvents.filter { $0.kind == .meeting }.count == 1 ? "1 meeting"
                         : "\(module.rangeEvents.filter { $0.kind == .meeting }.count) meetings")
                        .font(Theme.font(11.5)).foregroundStyle(Theme.textSecondary)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            if module.span == .day, step < 4 {
                WeekStrip(counts: module.weekCounts, today: module.todayIndex, notes: module.weekNotes, now: R5Clock.now(clock),
                          shown: module.shownIndex) { index in
                    module.showDay(index - module.todayIndex)
                }
            }
        }
    }

    /// "No meetings · free until 09:30", "3 meetings · Design review until 13:00".
    /// Short: "No meetings · busy until 09:00" when the event's title doesn't fit.
    private func summary(_ now: Date, short: Bool) -> String {
        let meetings = module.meetingCount
        let count = meetings == 0 ? (module.events.isEmpty ? "Nothing planned" : "No meetings")
            : meetings == 1 ? "1 meeting" : "\(meetings) meetings"
        guard !module.events.isEmpty, module.isToday else { return count }
        var status = module.dayStatus(now: now)
        if short, !status.hasPrefix("free"), let until = status.range(of: " until ", options: .backwards) {
            status = "busy" + status[until.lowerBound...]
        }
        return "\(count) · \(status)"
    }
}

/// Day, Week, Month (also D, W, M).
private struct SpanPicker: View {
    let module: AgendaModule
    /// First letters only, where the header is narrow.
    var short = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AgendaModule.Span.allCases, id: \.self) { span in
                let selected = module.span == span
                Button { module.setSpan(span) } label: {
                    Text(short ? String(Localization.string(span.rawValue).prefix(1)) : Localization.string(span.rawValue))
                        .font(Theme.font(10.5, .semibold))
                        .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                        .padding(.horizontal, 7)
                        .frame(height: 18)
                        .background(Color.white.opacity(selected ? 0.14 : 0), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(PressScale())
                .help("\(span.rawValue) (\(span.rawValue.prefix(1)))")
            }
        }
        .padding(2)
        .background(Color.white.opacity(0.05), in: Capsule())
    }
}

/// Seven columns, Monday first: each day's events with their time; a click opens the day.
private struct WeekView: View {
    let module: AgendaModule
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(module.spanDays, id: \.self) { day in
                let isToday = Calendar.current.isDate(day, inSameDayAs: now)
                let events = module.events(on: day)
                Button { module.open(day: day) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Text(day.formatted(.dateTime.weekday(.abbreviated)))
                                .font(Theme.font(10.5, .medium)).foregroundStyle(isToday ? Theme.accent : Theme.textTertiary)
                            Text("\(Calendar.current.component(.day, from: day))")
                                .font(Theme.font(12, .semibold).monospacedDigit())
                                .foregroundStyle(isToday ? Color.white : Theme.textBody)
                                .padding(.horizontal, isToday ? 5 : 0)
                                .background { if isToday { Capsule().fill(Theme.accent) } }
                        }
                        // As many events as the column holds, the rest as "+n".
                        ViewThatFits(in: .vertical) {
                            ForEach((0...min(events.count, 12)).reversed(), id: \.self) { shown in
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(events.prefix(shown)) { row($0) }
                                    if shown < events.count {
                                        Text("+\(events.count - shown)").font(Theme.font(10)).foregroundStyle(Theme.textTertiary)
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: .infinity, alignment: .top)
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Theme.card.opacity(isToday ? 1.6 : 1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressScale())
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func row(_ event: CalEvent) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(TimeText.clock(event.start)).font(Theme.font(9.5).monospacedDigit()).foregroundStyle(Theme.textTertiary)
            Text(event.title).font(Theme.font(10.5, .medium)).foregroundStyle(Theme.textBody).lineLimit(2)
        }
        .padding(.leading, 5)
        .overlay(alignment: .leading) { Rectangle().fill(event.calendar.color).frame(width: 2) }
        .opacity(event.end <= now ? 0.5 : 1)
    }
}

/// The month as a grid, Monday first: a dot per meeting (up to three); a click opens the day.
/// The rows share the panel's height, so five or six weeks fit without scrolling.
private struct MonthView: View {
    let module: AgendaModule
    let now: Date
    private let letters = ["M", "T", "W", "T", "F", "S", "S"]

    var body: some View {
        GeometryReader { proxy in
            let weeks = max(1, module.spanDays.count / 7)
            grid(cell: min(44, max(26, (proxy.size.height - 22 - CGFloat(weeks - 1) * 4) / CGFloat(weeks))))
        }
    }

    private func grid(cell: CGFloat) -> some View {
        let month = Calendar.current.component(.month, from: module.shownDate)
        return VStack(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(0..<7, id: \.self) { index in
                    Text(letters[index]).font(Theme.font(10, .medium)).foregroundStyle(Theme.textTertiary).frame(maxWidth: .infinity)
                }
            }
            .frame(height: 18)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(module.spanDays, id: \.self) { day in
                    let isToday = Calendar.current.isDate(day, inSameDayAs: now)
                    let inMonth = Calendar.current.component(.month, from: day) == month
                    let events = module.events(on: day)
                    Button { module.open(day: day) } label: {
                        VStack(spacing: 3) {
                            Text("\(Calendar.current.component(.day, from: day))")
                                .font(Theme.font(11.5, isToday ? .semibold : .medium).monospacedDigit())
                                .foregroundStyle(isToday ? Color.white : inMonth ? Theme.textBody : Theme.textTertiary)
                                .frame(width: 22, height: 18)
                                .background { if isToday { Capsule().fill(Theme.accent) } }
                            HStack(spacing: 2) {
                                ForEach(Array(events.prefix(3).enumerated()), id: \.offset) { _, event in
                                    Circle().fill(event.calendar.color).frame(width: 4, height: 4)
                                }
                            }
                            .frame(height: 4)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: cell)
                        .background(Theme.card.opacity(inMonth ? 1 : 0.4), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScale())
                    .help(events.isEmpty ? "" : events.prefix(4).map { "\(TimeText.clock($0.start)) \($0.title)" }.joined(separator: "\n"))
                }
            }
        }
    }
}

/// The day's name with arrows to the day before and after, "Today" to come back, and a way to
/// the full view in Calendar.
private struct DayHeader: View {
    let module: AgendaModule
    let now: Date
    /// "Thu 29 Oct" instead of "Thursday 29 October".
    var short = false
    /// "D W M" instead of "Day Week Month".
    var shortSpans = false

    var body: some View {
        HStack(spacing: 4) {
            // The long date where the row has room ("Thursday 29 October"), else the short one.
            Text(short ? shortTitle : title).fixedSize()
            .font(Theme.font(13.5, .semibold)).foregroundStyle(Theme.textPrimary)
            .lineLimit(1)
            .layoutPriority(1)
            arrow("chevron.left", help: "Back (⌘←)") { module.step(by: -1) }
            arrow("chevron.right", help: "Ahead (⌘→)") { module.step(by: 1) }
            SpanPicker(module: module, short: shortSpans).fixedSize()
            if !module.isToday {
                Button("Today") { module.showDay(0); module.step(by: 0) }
                    .buttonStyle(PressScale())
                    .font(Theme.font(11, .semibold))
                    .foregroundStyle(Theme.accent)
                    .help("Back to today (T)")
            }
            if let source = module.source {
                arrow("arrow.up.forward.app", help: "Open Calendar") { source.openCalendarApp() }
            }
            if module.canAddEvents, module.eventDraft == nil {
                arrow("plus", help: "New event") { module.startEvent() }
            }
        }
    }

    /// "Thu 29 Oct" ("Do., 29. Okt.") in a narrow header, in the user's locale; the week and the
    /// month keep theirs.
    private var shortTitle: String {
        guard module.span == .day else { return title }
        return now.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    /// "Wednesday, 28 October", "Week 44 · 26 Oct – 1 Nov", "October 2026".
    private var title: String {
        switch module.span {
        case .day:
            return R5Clock.longDay(now)
        case .week:
            let days = module.spanDays
            guard let first = days.first, let last = days.last else { return "" }
            let week = Calendar.current.component(.weekOfYear, from: first)
            let style = Date.FormatStyle().day().month(.abbreviated)
            return "Week \(week) · \(first.formatted(style)) – \(last.formatted(style))"
        case .month:
            return module.shownDate.formatted(.dateTime.month(.wide).year())
        }
    }

    private func arrow(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .help(help)
    }
}

/// The week, readable: weekday, date, and a dot per meeting (up to three), today in the accent.
struct WeekStrip: View {
    let counts: [Int]
    let today: Int
    var notes: [Int: String] = [:]
    let now: Date
    /// The day on show when it isn't today: a ring around its date.
    var shown: Int? = nil
    /// A click on a day shows it.
    var onSelect: ((Int) -> Void)? = nil

    private let letters = ["M", "T", "W", "T", "F", "S", "S"]

    var body: some View {
        let monday = Calendar.current.date(byAdding: .day, value: -today, to: Calendar.current.startOfDay(for: now)) ?? now
        HStack(spacing: 4) {
            ForEach(0..<7, id: \.self) { index in
                let date = Calendar.current.date(byAdding: .day, value: index, to: monday) ?? now
                let isToday = index == today
                VStack(spacing: 2) {
                    Text(letters[index])
                        .font(Theme.font(9.5, .medium))
                        .foregroundStyle(isToday ? Theme.accent : Theme.textTertiary)
                    Text("\(Calendar.current.component(.day, from: date))")
                        .font(Theme.font(12, isToday ? .semibold : .medium).monospacedDigit())
                        .foregroundStyle(isToday ? Color.white : index < today ? Theme.textTertiary : Theme.textBody)
                        .frame(width: 22, height: 18)
                        .background { if isToday { Capsule().fill(Theme.accent) } }
                        .overlay { if shown == index && !isToday { Capsule().strokeBorder(Theme.accent, lineWidth: 1.5) } }
                    HStack(spacing: 2) {
                        ForEach(0..<min(3, counts[index]), id: \.self) { _ in
                            Circle().fill(index < today ? Color.white.opacity(0.25) : Theme.textSecondary).frame(width: 3, height: 3)
                        }
                    }
                    .frame(height: 3)
                }
                .frame(width: 24)
                .contentShape(Rectangle())
                .onTapGesture { onSelect?(index) }
                .help(notes[index].map { "\(counts[index]) meetings · \($0)" } ?? (counts[index] == 1 ? "1 meeting" : "\(counts[index]) meetings"))
            }
        }
    }
}

/// Before calendar access: one line and, if declined, the way to System Settings.
private struct AgendaAccess: View {
    let source: CalendarModule

    var body: some View {
        NotchCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("Your day").font(Theme.font(14, .semibold)).foregroundStyle(Theme.textPrimary)
                Text(source.access == .denied
                     ? "Calendar access is off. Turn it on in System Settings to see your day here."
                     : "Allow calendar access to see your day, the next meeting and its prep here.")
                    .font(Theme.font(12)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if source.access == .denied {
                    Button("Open Privacy Settings") { source.openPrivacySettings() }
                        .buttonStyle(PressScale())
                        .font(Theme.font(12, .medium))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .onAppear { source.requestAccessIfNeeded() }
    }
}

private struct AgendaList: View {
    let module: AgendaModule
    let now: Date

    /// Next to the briefing the list is narrow: durations only.
    var narrow: Bool { module.showsDetail }

    enum Row: Identifiable {
        case event(CalEvent), gap(DayGaps.Gap), now
        var id: String {
            switch self {
            case .event(let e): e.id
            case .gap(let g): "gap-\(g.start)"
            case .now: "now"
            }
        }
        var minute: Double {
            switch self {
            case .event(let e): e.startMinutes
            case .gap(let g): g.start + 0.5
            case .now: -1
            }
        }
    }

    var rows: [Row] {
        let nowMinutes = R5Clock.minutes(now)
        var rows: [Row] = module.events.map { .event($0) } + module.gaps(now: now).filter { $0.minutes >= 60 }.map { .gap($0) }
        rows.sort { $0.minute < $1.minute }
        let index = rows.firstIndex { row in
            if case .event(let e) = row { return e.end > now && e.startMinutes >= nowMinutes }
            if case .gap(let g) = row { return g.start >= nowMinutes - 1 }
            return false
        } ?? rows.count
        if module.isToday { rows.insert(.now, at: index) }
        return rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(rows) { row in
                Group {
                    switch row {
                    case .event(let event): eventRow(event)
                    case .gap(let gap):
                        HStack(spacing: 8) {
                            Text(TimeText.clockMinutes(gap.start)).frame(width: 36, alignment: .leading)
                            Rectangle().fill(Color.white.opacity(0.08)).frame(width: 2.5, height: 10)
                            Text("\(DayGaps.label(gap)) · \(DayGaps.duration(gap.minutes))")
                        }
                        .font(Theme.font(11).monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 6)
                        .frame(height: 20)
                    case .now:
                        HStack(spacing: 6) {
                            Text(TimeText.clock(now)).font(Theme.font(10.5, .semibold).monospacedDigit()).foregroundStyle(Theme.accent)
                                .frame(width: 36, alignment: .leading)
                            Circle().fill(Theme.accent).frame(width: 5, height: 5)
                            Rectangle().fill(Theme.accent.opacity(0.7)).frame(height: 1)
                        }
                        .shadow(color: Theme.accent.opacity(0.8), radius: 3)
                        .padding(.horizontal, 6)
                        .frame(height: 12)
                    }
                }
                .id(row.id)
            }
        }
    }

    private func eventRow(_ event: CalEvent) -> some View {
        let selected = module.selected?.id == event.id
        let past = event.end <= now
        return HoverRow(cornerRadius: 8, restOpacity: selected ? 0.09 : 0, hoverOpacity: 0.07) {
            module.select(event)
        } label: {
            HStack(spacing: 8) {
                Text(TimeText.clock(event.start))
                    .font(Theme.font(11.5).monospacedDigit())
                    .foregroundStyle(past ? Theme.textTertiary : Theme.textSecondary)
                    .frame(width: 36, alignment: .leading)
                Group {
                    if event.kind == .meeting {
                        RoundedRectangle(cornerRadius: 1.5).fill(event.calendar.color)
                    } else {
                        Hatch(color: event.calendar.color.opacity(0.8), spacing: 3).clipShape(RoundedRectangle(cornerRadius: 1.5))
                    }
                }
                .frame(width: 2.5, height: 16)
                .shadow(color: selected ? event.calendar.color : .clear, radius: 4)
                Text(event.title)
                    .font(Theme.font(12.5, event.kind == .meeting ? .medium : .regular))
                    .foregroundStyle(past ? Theme.textTertiary : event.kind == .meeting ? Theme.textPrimary : Theme.textSecondary)
                Spacer(minLength: 4)
                if event.link != nil {
                    Image(systemName: "video").font(.system(size: 9.5)).foregroundStyle(Theme.textTertiary)
                }
                // How long, and until when for long ones: "8 h 30 · until 18:00".
                Text(event.endMinutes - event.startMinutes >= 120 && !narrow
                     ? "\(DayGaps.duration(event.endMinutes - event.startMinutes)) · until \(TimeText.clock(event.end))"
                     : DayGaps.duration(event.endMinutes - event.startMinutes))
                    .font(Theme.font(10.5).monospacedDigit()).foregroundStyle(Theme.textTertiary)
            }
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(height: 24)
        }
        .activeGlow(selected, color: event.calendar.color, radius: 8)
    }
}

/// The calendar's "+": the title (a day, a time and a length in it count, "Lunch tomorrow 13:00
/// 1h"), the day, the time and the length as chips, and the calendar it goes to. ↵ adds it, esc
/// cancels; macOS asks for calendar access on the first save if it never asked.
private struct EventComposer: View {
    let module: AgendaModule
    @FocusState private var focused: Bool
    @Environment(\.locale) private var locale

    var body: some View {
        let draft = module.eventDraft ?? EventDraft(day: module.shownDate, now: module.now, calendar: .current)
        NotchCard(padding: 12) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    Text("New event").font(Theme.font(11.5, .semibold)).foregroundStyle(Theme.accent)
                    Spacer(minLength: 6)
                    if let calendar = module.newEventCalendar {
                        Circle().fill(calendar.color).frame(width: 6, height: 6)
                        Text(verbatim: calendar.title).font(Theme.font(11.5)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                }
                TextField("Lunch with Ada 13:00", text: Binding(get: { module.eventDraft?.text ?? "" }, set: { module.updateEvent(text: $0) }))
                    .textFieldStyle(.plain)
                    .font(Theme.font(14.5, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .focused($focused)
                    .onSubmit { module.saveEvent() }
                    .simultaneousGesture(TapGesture().onEnded { NotchPanel.takeKeyboard() })
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                HStack(spacing: 6) {
                    stepper(dayLabel(draft.start), help: "The day") { module.shiftEvent(days: $0) }
                    stepper(Text(verbatim: "\(TimeText.clock(draft.start))–\(TimeText.clock(draft.end))"), help: "The start, in quarter hours") {
                        module.shiftEvent(minutes: 15 * $0)
                    }
                    Button { module.nextEventLength() } label: {
                        Text(verbatim: DayGaps.duration(Double(draft.minutes)))
                            .font(Theme.font(11.5, .medium).monospacedDigit())
                            .foregroundStyle(Theme.textBody)
                            .padding(.horizontal, 9)
                            .frame(height: 24)
                            .background(Color.white.opacity(0.07), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PressScale())
                    .help("How long: 15 min to 2 h. Or type it: 30 min, 1h")
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    if let error = module.eventError {
                        Text(LocalizedStringKey(error)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        if let source = module.source, CalendarModule.currentAccess() == .denied {
                            Button("Open Privacy Settings") { Haptics.tick(); source.openPrivacySettings() }
                                .buttonStyle(PressScale())
                                .foregroundStyle(Theme.accent)
                        }
                    } else {
                        Text("↵ add  esc").foregroundStyle(Theme.textTertiary)
                    }
                    Spacer(minLength: 6)
                    Button { module.saveEvent() } label: {
                        Text("Add").font(Theme.font(12, .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .frame(height: 24)
                            .background(Theme.accent.opacity(draft.canSave ? 1 : 0.35), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PressScale())
                    .disabled(!draft.canSave || module.savingEvent)
                    .help("Add to the calendar (↵)")
                }
                .font(Theme.font(11))
            }
        }
        .onAppear {
            NotchPanel.takeKeyboard()
            focused = true
        }
    }

    /// "Today", "Tomorrow", "Fri 6 Nov".
    private func dayLabel(_ date: Date) -> Text {
        let calendar = Calendar.current
        let offset = calendar.dateComponents([.day], from: calendar.startOfDay(for: module.now), to: calendar.startOfDay(for: date)).day
        switch offset {
        case 0: return Text("Today")
        case 1: return Text("Tomorrow")
        default: return Text(verbatim: date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(locale)))
        }
    }

    /// A value with arrows on both sides; `step` gets -1 or 1.
    private func stepper(_ label: Text, help: LocalizedStringKey, step: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 0) {
            arrow("chevron.left") { step(-1) }
            label.font(Theme.font(11.5, .medium).monospacedDigit()).foregroundStyle(Theme.textBody).lineLimit(1).fixedSize()
            arrow("chevron.right") { step(1) }
        }
        .frame(height: 24)
        .background(Color.white.opacity(0.07), in: Capsule())
        .help(help)
    }

    private func arrow(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 22, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
    }
}

/// The selected meeting as a briefing: who, what is open with them, and the one action. Check
/// camera turns the card into the camera's mirrored picture until it's closed or the card goes.
private struct Briefing: View {
    let module: AgendaModule
    let event: CalEvent
    let now: Date

    var body: some View {
        // One container, so switching to the camera and back isn't the card leaving.
        ZStack {
            if module.camera.meetingID == event.id, module.camera.card == .preview, let link = event.link {
                CameraCheckCard(module: module, event: event, link: link, now: now)
                    .transition(.blurSlide(scale: 0.97))
            } else {
                briefing
            }
        }
        .onDisappear { module.cardLeft(event) }
    }

    private var briefing: some View {
        NotchCard(padding: 12) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.title).font(Theme.font(15, .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        HStack(spacing: 5) {
                            Text("\(TimeText.clock(event.start))–\(TimeText.clock(event.end))").monospacedDigit()
                            Text("·")
                            Text(R5Clock.countdown(start: event.start, end: event.end, now: now))
                                .foregroundStyle(event.kind == .meeting && event.start.timeIntervalSince(now) <= 15 * 60 && event.end > now
                                                 ? Theme.accent : Theme.textSecondary)
                                .contentTransition(.numericText())
                            if let link = event.link {
                                Text("·")
                                Text(link.provider.displayName)
                            } else if let location = event.location {
                                Text("·")
                                Text(location)
                            }
                        }
                        .font(Theme.font(12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        if let leave = module.leave, leave.enabled, module.isToday {
                            LeaveLine(leave: leave, event: event, now: now)
                        }
                    }
                    Spacer(minLength: 8)
                    // Join stays in reach at the top; the prep below scrolls in the fixed panel.
                    if let link = event.link, event.end > now {
                        HStack(spacing: 6) {
                            if module.cameraCheckOn { CameraCheckButton(module: module, event: event) }
                            JoinPill(link: link) { module.open(event) }
                        }
                    } else {
                        Circle().fill(event.calendar.color).frame(width: 7, height: 7).padding(.top, 6)
                            .help(event.calendar.rawValue)
                    }
                }
                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.vertical, 10)
                if module.camera.meetingID == event.id, module.camera.card == .accessOff {
                    CameraAccessNote()
                        .transition(.blurSlide(y: 4))
                } else {
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 10) {
                            PrepList(module: module, event: event, avatarSize: 30, maxPeople: 3, maxItems: 4, noteLines: 2)
                            if module.hasNote(for: event) {
                                QuietLink(title: "Open note") { module.openNote(for: event) }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollIndicators(.never)
                    .scrollEdgeFade()
                }
            }
        }
    }
}

/// Time to leave in the event's card: when to go and how long the way takes, "Leave now" once
/// it's time; with the location never asked, the click that asks for it. Nothing once it started.
private struct LeaveLine: View {
    let leave: LeaveTimes
    let event: CalEvent
    let now: Date

    var body: some View {
        if event.start > now, let estimate = leave.estimates[event.id] {
            let due = TimeToLeave.isDue(start: event.start, travel: estimate.travel, now: now)
            let leaveAt = TimeText.clock(TimeToLeave.leaveAt(start: event.start, travel: estimate.travel))
            HStack(spacing: 5) {
                Image(systemName: estimate.fromCalendar ? "calendar.badge.clock" : estimate.mode.symbol)
                    .font(.system(size: 10.5, weight: .semibold))
                Text(due ? Localization.string("Leave now") : String(format: Localization.string("Leave at %@"), leaveAt))
                    .font(Theme.font(12, .semibold))
                    .contentTransition(.numericText())
                Text(verbatim: "· \(TimeToLeave.duration(estimate.travel))")
                    .foregroundStyle(Theme.textSecondary)
            }
            .font(Theme.font(12))
            .foregroundStyle(due ? Theme.accent : Theme.textBody)
            .lineLimit(1)
            .padding(.top, 2)
            .help(estimate.fromCalendar ? "The travel time set in Calendar" : "Worked out by Apple Maps from where you are")
        } else if event.start > now, leave.offersLocation(for: event.id) {
            QuietLink(title: Localization.string("Time to leave: use my location"), symbol: "location") { leave.useMyLocation() }
                .padding(.top, 2)
                .help("macOS asks once; Apple Maps then works out the way from where you are")
        }
    }
}

/// Check camera beside Join: a quiet square; the picture opens in the card.
private struct CameraCheckButton: View {
    let module: AgendaModule
    let event: CalEvent

    var body: some View {
        let off = module.mirror.access == .denied
        Button { module.checkCamera(event) } label: {
            Image(systemName: off ? "video.slash" : "web.camera")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(off ? Theme.textSecondary : Theme.textBody)
                .frame(width: 30, height: 26)
                .background(Color.white.opacity(module.camera.meetingID == event.id ? 0.14 : 0.08),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .help(off ? "Camera access is off. Click to open System Settings." : "Check camera: a mirrored preview, nothing is recorded")
        .accessibilityLabel("Check camera")
    }
}

/// The camera check in place of the briefing: the mirrored live picture fills the card, the
/// meeting on top with the close button, Join right beside the picture.
private struct CameraCheckCard: View {
    let module: AgendaModule
    let event: CalEvent
    let link: MeetingLink
    let now: Date

    var body: some View {
        CameraPreview(mirror: module.mirror)
            .overlay {
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.title).font(Theme.font(14, .semibold)).foregroundStyle(.white)
                            Text(R5Clock.countdown(start: event.start, end: event.end, now: now))
                                .font(Theme.font(11.5).monospacedDigit()).foregroundStyle(.white.opacity(0.75))
                        }
                        .lineLimit(1)
                        Spacer(minLength: 8)
                        Button {
                            Haptics.tick()
                            module.closeCamera()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(Color.black.opacity(0.45), in: Circle())
                                .contentShape(Circle())
                        }
                        .buttonStyle(PressScale())
                        .help("Close the camera")
                        .accessibilityLabel("Close the camera")
                    }
                    Spacer(minLength: 0)
                    HStack(alignment: .center, spacing: 8) {
                        Label("Only you see this. Nothing is recorded.", systemImage: "lock.fill")
                            .font(Theme.font(11, .medium))
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        Spacer(minLength: 6)
                        JoinPill(link: link) { module.open(event) }
                    }
                }
                .padding(10)
                .background {
                    // Scrims keep the words readable on any picture.
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom).frame(height: 56)
                        Spacer(minLength: 0)
                        LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .top, endPoint: .bottom).frame(height: 56)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// Camera access is off: what to switch on, and where (System Settings opened with the click).
private struct CameraAccessNote: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Camera access is off", systemImage: "video.slash")
                .font(Theme.font(12.5, .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Turn \(Brand.displayName) on in System Settings › Privacy & Security › Camera, then check again.")
                .font(Theme.font(12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            QuietLink(title: Localization.string("Open System Settings")) {
                Haptics.tick()
                PrivacyPane.open("Privacy_Camera")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension TimeText {
    static func clockMinutes(_ minutes: Double) -> String { DayGaps.clock(minutes) }
}
