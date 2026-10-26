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

    init(variant: Variant, people: (any PeopleProvider)?, source: CalendarModule? = nil) {
        self.variant = variant
        self.people = people
        self.source = source
        mockEvents = source == nil ? AgendaSamples.day(R5Clock.now()) : []
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

    /// Shows another day; 0 goes back to today.
    func showDay(_ offset: Int) {
        guard offset != dayOffset else { return }
        Haptics.tick()
        withAnimation(Theme.snappy) {
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

    /// The agenda's detail side shows (a meeting with prep is next, or the user picked one).
    var showsDetail: Bool { variant == .b && selected != nil }

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

    // MARK: NotchModule

    var ambientPriority: Int {
        guard let next = nextMeeting else { return 0 }
        return next.start.timeIntervalSince(now) <= 15 * 60 ? 30 : 0
    }

    var needsAttention: Bool {
        guard let next = nextMeeting, next.kind == .meeting else { return false }
        return next.start.timeIntervalSince(now) <= 5 * 60 && next.end > now
    }

    /// Variant A: the band above the meeting and prep cards. Variant B sizes to its content:
    /// header, the band (one row per lane), and the agenda list or the briefing, whichever is taller.
    var bodyHeight: CGFloat {
        guard variant == .b else { return 400 }
        let list = AgendaList.height(module: self, now: viewNow(now)) + 20
        let lower = showsDetail ? max(236, list) : list
        return min(NotchLayout.maxBodyHeight, 32 + 8 + DayBand.height(lanes: laneCount) + 16 + 8 + lower)
    }

    /// Compact (the agenda's width) until a detail opens; then the full panel.
    var bodyWidth: CGFloat { showsDetail || variant == .a ? NotchLayout.expandedWidth : NotchLayout.minExpandedWidth }

    var holdsOpen: Bool { selectedID != nil }

    func handleBack() -> Bool {
        guard showsDetail else { return false }
        withAnimation(Theme.snappy) {
            selectedID = nil
            detailDismissed = true
        }
        return true
    }

    func setExpanded(_ expanded: Bool) {
        if !expanded {
            selectedID = nil
            detailDismissed = false
            dayOffset = 0
            otherDay = []
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
        switch press.key {
        case .upArrow, .downArrow:
            return step(press.key == .downArrow ? 1 : -1)
        case .leftArrow where press.modifiers.contains(.command), .rightArrow where press.modifiers.contains(.command):
            showDay(dayOffset + (press.key == .rightArrow ? 1 : -1))
            return true
        default:
            if press.characters == "t", dayOffset != 0 {
                showDay(0)
                return true
            }
            return false
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
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        DayHeader(module: module, now: now)
                        ViewThatFits(in: .horizontal) {
                            Text(summary(now, short: false)).fixedSize()
                            Text(summary(now, short: true))
                        }
                        .font(Theme.font(11.5)).foregroundStyle(Theme.textSecondary)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 8)
                    WeekStrip(counts: module.weekCounts, today: module.todayIndex, notes: module.weekNotes, now: R5Clock.now(context.date),
                              shown: module.shownIndex) { index in
                        module.showDay(index - module.todayIndex)
                    }
                }
                .padding(.horizontal, 6)
                .frame(height: 32)

                NotchCard(padding: 8) {
                    DayBand(module: module, now: now)
                }
                .frame(height: DayBand.height(lanes: module.laneCount) + 16)

                HStack(alignment: .top, spacing: 10) {
                    NotchCard(padding: 10) {
                        AgendaList(module: module, now: now)
                    }
                    .frame(width: module.showsDetail ? 256 : nil)

                    if let event = module.selected {
                        Briefing(module: module, event: event, now: now)
                            .id(event.id)
                            .transition(.blurSlide(x: 10))
                    }
                }
            }
        }
        .onAppear { module.source?.requestAccessIfNeeded() }
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

/// The day's name with arrows to the day before and after, "Today" to come back, and a way to
/// the full view in Calendar.
private struct DayHeader: View {
    let module: AgendaModule
    let now: Date

    var body: some View {
        HStack(spacing: 4) {
            Text(R5Clock.longDay(now)).font(Theme.font(13.5, .semibold)).foregroundStyle(Theme.textPrimary)
                .layoutPriority(1)
            arrow("chevron.left", help: "Day before (⌘←)") { module.showDay(module.dayOffset - 1) }
            arrow("chevron.right", help: "Day after (⌘→)") { module.showDay(module.dayOffset + 1) }
            if !module.isToday {
                Button("Today") { module.showDay(0) }
                    .buttonStyle(PressScale())
                    .font(Theme.font(11, .semibold))
                    .foregroundStyle(Theme.accent)
                    .help("Back to today (T)")
            }
            if let source = module.source {
                arrow("arrow.up.forward.app", help: "Open Calendar") { source.openCalendarApp() }
            }
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

    /// The list's height, for the panel: events 24, free stretches 20, the now line 12, 1 between.
    static func height(module: AgendaModule, now: Date) -> CGFloat {
        let rows = AgendaList(module: module, now: now).rows
        return rows.reduce(0) { total, row in
            switch row {
            case .event: total + 25
            case .gap: total + 21
            case .now: total + 13
            }
        }
    }

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

/// The selected meeting as a briefing: who, what is open with them, and the one action.
private struct Briefing: View {
    let module: AgendaModule
    let event: CalEvent
    let now: Date

    var body: some View {
        NotchCard(padding: 14) {
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
                    }
                    Spacer(minLength: 8)
                    Circle().fill(event.calendar.color).frame(width: 7, height: 7).padding(.top, 6)
                        .help(event.calendar.rawValue)
                }
                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.vertical, 12)
                PrepList(module: module, event: event, avatarSize: 30, maxPeople: 3, maxItems: 4, noteLines: 2)
                Spacer(minLength: 8)
                HStack {
                    if module.hasNote(for: event) {
                        QuietLink(title: "Open note") { module.openNote(for: event) }
                    }
                    Spacer()
                    Text("↑↓ events").font(Theme.font(11)).foregroundStyle(Theme.textTertiary)
                    if let link = event.link, event.end > now {
                        JoinPill(link: link) { module.open(event) }
                    }
                }
                .frame(height: 26)
            }
        }
    }
}

extension TimeText {
    static func clockMinutes(_ minutes: Double) -> String { DayGaps.clock(minutes) }
}
