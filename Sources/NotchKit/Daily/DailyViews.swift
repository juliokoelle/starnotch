import NotchCore
import SwiftUI

// The daily tools in the notch: a quiet chip in the calendar's header, the day card it opens,
// and the ears at rest (weather, day progress) when the user put them there.

/// How much of the work day is done, as a thin ring.
struct DayRing: View {
    var progress: Double
    var size: CGFloat = 12
    var lineWidth: CGFloat = 2

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.14), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}

/// What the day's progress says right now, for the chip, the card and the ears.
struct DayStatus {
    let phase: WorkDay.Phase
    let day: WorkDay

    init(_ day: WorkDay, now: Date) {
        self.day = day
        phase = day.phase(at: now)
    }

    var progress: Double {
        switch phase {
        case .off, .before: 0
        case .during(let done): done
        case .after: 1
        }
    }

    var percent: String { "\(Int((progress * 100).rounded(.down))) %" }

    /// "3 h 10 min left", "Starts at 09:00", "Done for today", "Weekend".
    var line: String {
        switch phase {
        case .off: String(localized: "Weekend")
        case .before: String(localized: "Starts at \(WorkDay.clock(day.start))")
        case .during(let done): String(localized: "\(WorkDay.duration(Int((Double(day.length) * (1 - done)).rounded(.up)))) left")
        case .after: String(localized: "Done for today")
        }
    }

    var isRunning: Bool { if case .during = phase { true } else { false } }
}

/// Weather, the day's progress and last night's headline score, quietly at the end of the day's
/// summary line; a click opens the day card.
struct DailyChip: View {
    let store: DailyStore
    @State private var hovering = false

    var body: some View {
        let weather = store.isOn(.weather) ? store.shownWeather : nil
        let day = store.isOn(.dayProgress) ? DayStatus(store.workDay, now: store.now) : nil
        let score = store.isOn(.health) ? store.health?.headline : nil
        if weather != nil || day?.isRunning == true || score != nil {
            Button {
                Haptics.tick()
                withAnimation(Theme.snappy) { store.cardShown = true }
            } label: {
                HStack(spacing: 7) {
                    if let weather {
                        HStack(spacing: 3) {
                            Image(systemName: weather.symbol).symbolRenderingMode(.hierarchical)
                                .font(.system(size: 10.5, weight: .medium))
                            Text(WeatherReport.degrees(weather.temperature)).monospacedDigit()
                        }
                    }
                    if let day, day.isRunning {
                        DayRing(progress: day.progress, size: 10, lineWidth: 1.6)
                            .help(day.percent)
                    }
                    if let score {
                        HStack(spacing: 3) {
                            Image(systemName: "heart.fill").font(.system(size: 8.5, weight: .semibold))
                            Text("\(score)").monospacedDigit()
                        }
                    }
                }
                .font(Theme.font(11.5, .medium))
                .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary)
                .padding(.horizontal, 6)
                .frame(height: 15)
                .background(Color.white.opacity(hovering ? 0.08 : 0), in: Capsule())
                // Sits in the summary line; the click area is 29 pt tall, more than the text.
                .contentShape(Rectangle().inset(by: -7))
            }
            .buttonStyle(PressScale())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.14), value: hovering)
            .help("Weather, your day and last night")
            .fixedSize()
        }
    }
}

/// The one switch between Today and the calendar, in the same place in both: the left of the
/// header. Today comes first and is where the tab opens; it has the day's to-dos (the connector's
/// tasks and Apple Reminders), the weather, the work day and last night.
struct CalendarTodaySwitch: View {
    let store: DailyStore
    @Namespace private var glide

    var body: some View {
        HStack(spacing: 2) {
            segment("Today", today: true)
            segment("Calendar", today: false)
        }
        .padding(2)
        .background(Color.white.opacity(0.06), in: Capsule())
        .fixedSize()
    }

    private func segment(_ title: LocalizedStringKey, today: Bool) -> some View {
        let selected = store.cardShown == today
        return Button {
            guard !selected else { return }
            Haptics.tick()
            withAnimation(Theme.snappy) { store.cardShown = today }
        } label: {
            Text(title).font(Theme.font(12, .semibold))
            .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background {
                if selected {
                    Capsule().fill(Color.white.opacity(0.14)).matchedGeometryEffect(id: "segment", in: glide)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(PressScale())
        .help(today ? Text("Today: to-dos, reminders, weather and last night") : Text("The calendar"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Today: the day's to-dos on the left (tasks from the notes and Apple Reminders, ticked off in
/// place), the weather, the work day and last night on the right. The calendar tab opens on it;
/// the switch shows the agenda instead.
struct DailyCard: View {
    let store: DailyStore

    var body: some View {
        let side = store.isOn(.weather) || store.isOn(.dayProgress) || store.isOn(.health)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                CalendarTodaySwitch(store: store)
                VStack(alignment: .leading, spacing: 1) {
                    Text(R5Clock.longDay(store.now)).font(Theme.font(13.5, .semibold)).foregroundStyle(Theme.textPrimary)
                    Text(summary).font(Theme.font(11.5)).foregroundStyle(Theme.textSecondary)
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                if store.isOn(.weather), let place = store.shownWeather?.place, !place.isEmpty {
                    Label(place, systemImage: store.settings.place == nil ? "location.fill" : "mappin")
                        .font(Theme.font(11.5)).foregroundStyle(Theme.textTertiary)
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 32)
            HStack(alignment: .top, spacing: 10) {
                TodoPanel(store: store)
                if side {
                    VStack(spacing: 8) {
                        if store.isOn(.weather) { WeatherPanel(store: store) }
                        if store.isOn(.dayProgress) || store.isOn(.health) {
                            HStack(spacing: 8) {
                                if store.isOn(.dayProgress) { DayPanel(store: store) }
                                if store.isOn(.health) { HealthPanel(store: store) }
                            }
                        }
                    }
                    // At most 290 pt, less on a narrower island: the cards shrink with it instead
                    // of pushing past the panel's edges, where they were cut off.
                    .frame(minWidth: 0, maxWidth: 290)
                    .layoutPriority(1)
                }
            }
        }
        // Asked again whenever Today shows: from the switch, or with the panel opening on it.
        .onAppear { store.today?.reload() }
    }

    /// "3 to do · 1 overdue", "Nothing due today".
    private var summary: String {
        let items = store.today?.todos ?? []
        guard !items.isEmpty else { return Localization.string("Nothing due today") }
        let today = AgentScanner.day(store.now)
        let overdue = items.filter { ($0.date.map { String($0.prefix(10)) } ?? today) < today }.count
        let count = String(format: Localization.string("%d to do"), items.count)
        return overdue > 0 ? count + " · " + String(format: Localization.string("%d overdue"), overdue) : count
    }
}

/// The day's to-dos: the connector's tasks and, when switched on, Apple Reminders due today or
/// overdue, then under "Later" the open reminders not due yet or without a date. A circle ticks
/// one off where it lives; a click on the title opens its place. Without
/// Reminders a quiet row offers them; macOS asks for access only on that click.
private struct TodoPanel: View {
    let store: DailyStore

    var body: some View {
        NotchCard(padding: 10) {
            VStack(alignment: .leading, spacing: 4) {
                let items = store.today?.todos ?? []
                let later = store.today?.later ?? []
                SectionLabel(title: Localization.string("To do"), trailing: items.isEmpty ? nil : "\(items.count)")
                    .padding(.horizontal, 6)
                if items.isEmpty && later.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Nothing due today").font(Theme.font(13, .medium)).foregroundStyle(Theme.textBody)
                        Text("Tasks from your notes and reminders due today show up here.")
                            .font(Theme.font(11.5)).foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 6)
                    .padding(.top, 4)
                    Spacer(minLength: 0)
                } else if let today = store.today {
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 1) {
                            if items.isEmpty {
                                Text("Nothing due today").font(Theme.font(12.5)).foregroundStyle(Theme.textSecondary)
                                    .frame(height: 28).padding(.horizontal, 6)
                            }
                            ForEach(items) { item in
                                TodoRow(module: today, item: item, now: store.now)
                                    .transition(.blurSlide(y: -4, scale: 0.98))
                            }
                            if !later.isEmpty {
                                SectionLabel(title: Localization.string("Later"), trailing: "\(later.count)")
                                    .padding(.horizontal, 6)
                                    .padding(.top, 8)
                                    .padding(.bottom, 2)
                                ForEach(later) { item in
                                    TodoRow(module: today, item: item, now: store.now)
                                        .transition(.blurSlide(y: -4, scale: 0.98))
                                }
                            }
                        }
                    }
                    .scrollIndicators(.never)
                    .scrollEdgeFade(bottom: 10)
                }
                if !store.remindersShown, store.turnOnReminders != nil { remindersOffer }
            }
        }
    }

    /// Apple Reminders aren't on: one row to bring them in.
    private var remindersOffer: some View {
        HStack(spacing: 10) {
            Image(systemName: "checklist").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 26, height: 26)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text("Apple Reminders").font(Theme.font(12, .medium)).foregroundStyle(Theme.textBody)
                Text("Ticked off here").font(Theme.font(10.5)).foregroundStyle(Theme.textTertiary)
            }
            .lineLimit(1)
            Spacer(minLength: 6)
            Button { store.turnOnReminders?() } label: {
                Text("Show").font(Theme.font(11.5, .semibold)).foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 10).frame(height: 24)
                    .background(Color.white.opacity(0.1), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(PressScale())
            .help("macOS asks once for access to your reminders")
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.horizontal, 6) }
    }
}

private struct TodoRow: View {
    let module: TodayModule
    let item: TodayModule.Item
    let now: Date
    @State private var hovering = false

    var body: some View {
        let done = module.doneIDs.contains(item.id)
        let reminder = item.id.hasPrefix("reminder-")
        HStack(spacing: 8) {
            if module.canComplete(item) {
                Button { module.complete(item) } label: {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(done ? TaraAccent.current : Theme.textSecondary)
                        .frame(width: 24, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressScale())
                .help(Localization.string(reminder ? "Mark as completed in Reminders" : "Tick off"))
                .accessibilityLabel(Text(verbatim: item.title))
                .accessibilityValue(done ? Text("Completed") : Text("Not completed"))
            } else {
                Circle().fill(Theme.textTertiary).frame(width: 5, height: 5).frame(width: 24, height: 28)
            }
            Button { module.openExternally(item) } label: {
                HStack(spacing: 8) {
                    Text(item.title)
                        .font(Theme.font(12.5)).foregroundStyle(done ? Theme.textTertiary : Theme.textBody)
                        .strikethrough(done, color: Theme.textTertiary)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    if let failure = module.failureText(item) {
                        Text(failure).font(Theme.font(11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    } else {
                        Text(when).font(Theme.font(11).monospacedDigit()).foregroundStyle(overdue ? Theme.textPrimary : Theme.textTertiary)
                            .fixedSize()
                        if reminder {
                            Image(systemName: "checklist").font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(Theme.textTertiary)
                                .help(item.detail.isEmpty ? Localization.string("Reminders") : item.detail)
                        }
                    }
                }
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScale())
            .help(Localization.string(item.help.isEmpty ? (reminder ? "Open in Reminders" : "Open") : item.help))
        }
        .padding(.trailing, 6)
        .background(Color.white.opacity(hovering ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering = $0 }
    }

    private var overdue: Bool { (item.date.map { String($0.prefix(10)) } ?? module.today) < module.today }

    /// "overdue", "today" or nothing for an undated task.
    private var when: String {
        guard let date = item.date else { return "" }
        return Localization.string(R5Clock.due(date, today: module.today))
    }
}

/// The weather now, the range, the next hours; without a place, one line and a way to set one.
private struct WeatherPanel: View {
    let store: DailyStore

    var body: some View {
        NotchCard(padding: 12) {
            if let weather = store.shownWeather {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: weather.symbol).symbolRenderingMode(.hierarchical)
                            .font(.system(size: 22, weight: .regular))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 28)
                        Text(WeatherReport.degrees(weather.temperature))
                            .font(Theme.font(24, .semibold).monospacedDigit()).foregroundStyle(Theme.textPrimary)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(LocalizedStringKey(weather.condition.title))
                            Text(DailyText.range(weather)).monospacedDigit()
                        }
                        .font(Theme.font(11.5)).foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    Text(store.weatherStatus == .offline ? String(localized: "Offline, from \(TimeText.clock(weather.fetched))")
                                                         : DailyText.outlook(weather, now: store.now))
                        .font(Theme.font(11.5)).foregroundStyle(Theme.textBody)
                        .lineLimit(1)
                    HStack(spacing: 0) {
                        ForEach(Array(weather.upcoming(from: store.now, count: 6).enumerated()), id: \.offset) { index, hour in
                            VStack(spacing: 3) {
                                Text(index == 0 ? String(localized: "Now") : hour.time.formatted(.dateTime.hour(.twoDigits(amPM: .omitted))))
                                    .font(Theme.font(10, .medium)).foregroundStyle(index == 0 ? Theme.textBody : Theme.textTertiary)
                                Image(systemName: hour.condition.symbol(isDay: hour.isDay)).symbolRenderingMode(.hierarchical)
                                    .font(.system(size: 12)).foregroundStyle(Theme.textBody)
                                    .frame(height: 15)
                                Text(WeatherReport.degrees(hour.temperature))
                                    .font(Theme.font(11.5, .medium).monospacedDigit()).foregroundStyle(Theme.textPrimary)
                            }
                            .frame(maxWidth: .infinity)
                            .help(hour.precipitation.map { $0 >= 20 ? String(localized: "Rain \($0) %") : "" } ?? "")
                        }
                    }
                }
            } else {
                let needsPlace = store.weatherStatus == .needsPlace
                DailyEmpty(symbol: needsPlace ? "location.slash" : "cloud.sun", title: weatherTitle,
                           text: weatherHint, action: needsPlace ? "Use my location" : nil,
                           perform: { store.useMyLocation() },
                           secondary: needsPlace ? "Set a city" : nil, performSecondary: { store.openSettings?() })
            }
        }
        .frame(height: 124)
        // Open-Meteo's data is CC BY 4.0; Settings › Daily has the links.
        .help("Weather data by Open-Meteo.com, CC BY 4.0")
    }

    private var weatherTitle: String {
        switch store.weatherStatus {
        case .needsPlace: store.locationDenied ? "Location is off" : "No location yet"
        case .offline: "Offline"
        default: "Weather"
        }
    }

    private var weatherHint: String {
        switch store.weatherStatus {
        case .needsPlace:
            store.locationDenied ? String(localized: "Opens System Settings › Location Services: turn on \(Brand.bundleName) there.")
                : store.locationAllowed ? String(localized: "macOS has no location right now. Try again, or set a city.")
                : String(localized: "Weather where this Mac is, or for a city you set.")
        case .offline: String(localized: "The weather comes back with the connection.")
        default: String(localized: "Looking up the weather…")
        }
    }
}

private struct DayPanel: View {
    let store: DailyStore

    var body: some View {
        let status = DayStatus(store.workDay, now: store.now)
        NotchCard(padding: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Work day").font(Theme.font(11.5, .semibold)).foregroundStyle(Theme.textSecondary)
                HStack(spacing: 8) {
                    DayRing(progress: status.progress, size: 26, lineWidth: 3.5)
                    Text(status.isRunning ? status.percent : status.progress >= 1 ? "✓" : "–")
                        .font(Theme.font(18, .semibold).monospacedDigit()).foregroundStyle(Theme.textPrimary)
                }
                Spacer(minLength: 0)
                Text(status.line).font(Theme.font(11.5)).foregroundStyle(Theme.textBody)
                    .lineLimit(1).minimumScaleFactor(0.85)
                    .help("\(WorkDay.clock(status.day.start)) – \(WorkDay.clock(status.day.end))")
            }
        }
    }
}

private struct HealthPanel: View {
    let store: DailyStore

    var body: some View {
        NotchCard(padding: 12) {
            if let health = store.health, !health.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Text("Last night").font(Theme.font(11.5, .semibold)).foregroundStyle(Theme.textSecondary)
                        Spacer(minLength: 0)
                        Text(health.source.title).font(Theme.font(10.5)).foregroundStyle(Theme.textTertiary)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    // Both scores where they fit, else the headline alone (the card is half the
                    // narrow column).
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 10) {
                            headline(health)
                            if let sleep = health.sleep {
                                metric("Sleep", value: sleep, unit: health.source == .whoop ? "%" : nil,
                                       level: HealthDay.sleepLevel(sleep, source: health.source))
                            }
                            Spacer(minLength: 0)
                        }
                        HStack { headline(health); Spacer(minLength: 0) }
                    }
                }
            } else {
                DailyEmpty(symbol: "heart", title: "Last night", text: healthHint, compact: true,
                           action: store.healthStatus == .loading ? nil : "Connect", perform: { store.openSettings?() })
            }
        }
    }

    @ViewBuilder private func headline(_ health: HealthDay) -> some View {
        if let headline = health.headline {
            metric(LocalizedStringKey(health.headlineTitle), value: headline, unit: health.recovery != nil ? "%" : nil,
                   level: HealthDay.level(headline, source: health.source))
        }
    }

    /// The score, and its name with a dot: green when good, Tara's colour when fair, red when low.
    private func metric(_ title: LocalizedStringKey, value: Int, unit: String?, level: HealthDay.Level) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text("\(value)").font(Theme.font(18, .semibold).monospacedDigit()).foregroundStyle(Theme.textPrimary)
                if let unit { Text(unit).font(Theme.font(10.5, .medium)).foregroundStyle(Theme.textSecondary) }
            }
            HStack(spacing: 4) {
                Circle().fill(level == .good ? Theme.ok : level == .fair ? Theme.waiting : Theme.critical).frame(width: 5, height: 5)
                Text(title).font(Theme.font(10.5)).foregroundStyle(Theme.textSecondary).lineLimit(1).fixedSize()
            }
        }
    }

    private var healthHint: String {
        switch store.healthStatus {
        case .failed(let message): message
        case .loading: "Fetching last night…"
        default: store.settings.healthSource == nil ? "Oura or WHOOP" : "Not connected yet"
        }
    }
}

/// A card without its data: what is missing in a few words and, where the user can do
/// something about it, one button.
private struct DailyEmpty: View {
    let symbol: String
    let title: String
    let text: String
    var compact = false
    var action: LocalizedStringKey?
    var perform: () -> Void = {}
    /// A second way out beside the first (weather: a city instead of the location).
    var secondary: LocalizedStringKey?
    var performSecondary: () -> Void = {}

    var body: some View {
        VStack(alignment: compact ? .leading : .center, spacing: compact ? 3 : 5) {
            if compact {
                Text(LocalizedStringKey(title)).font(Theme.font(11.5, .semibold)).foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
            } else {
                Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                Text(LocalizedStringKey(title)).font(Theme.font(12.5, .semibold)).foregroundStyle(Theme.textPrimary)
            }
            Text(LocalizedStringKey(text)).font(Theme.font(11.5)).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(compact ? .leading : .center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                HStack(spacing: 6) {
                    button(action, perform)
                    if let secondary { button(secondary, performSecondary) }
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: compact ? .topLeading : .center)
    }

    private func button(_ title: LocalizedStringKey, _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Text(title).font(Theme.font(11.5, .semibold)).foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 10).frame(height: 22)
                .background(Color.white.opacity(0.1), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(PressScale())
    }
}

/// Beside the notch at rest, when no module has anything to show and the user put the weather
/// or the day's progress there. Weather alone: its symbol and the temperature; progress alone:
/// the ring and the percent; both: the ring left, the temperature right.
@MainActor
final class DailyEars: NotchModule {
    let kind = ModuleKind.calendar
    let symbol = "sun.max"
    let store: DailyStore

    init(store: DailyStore) { self.store = store }

    private var weather: WeatherReport? {
        store.isOn(.weather) && store.settings.weatherInEar ? store.shownWeather : nil
    }

    private var day: DayStatus? {
        guard store.isOn(.dayProgress), store.settings.progressInEar else { return nil }
        let status = DayStatus(store.workDay, now: store.now)
        return status.isRunning ? status : nil
    }

    /// Something to show: then the island takes these ears at rest.
    var shown: NotchModule? { weather != nil || day != nil ? self : nil }

    func leadingEar(peek: Bool) -> AnyView {
        if let day {
            return AnyView(DayRing(progress: day.progress, size: 12, lineWidth: 2))
        }
        if let weather {
            return AnyView(Image(systemName: weather.symbol).symbolRenderingMode(.hierarchical)
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textBody))
        }
        return AnyView(EmptyView())
    }

    func trailingEar(peek: Bool) -> AnyView {
        let text = weather.map { WeatherReport.degrees($0.temperature) } ?? day?.percent
        return AnyView(Text(text ?? "")
            .font(Theme.font(11, .semibold).monospacedDigit())
            .foregroundStyle(Theme.textBody)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .fixedSize())
    }

    /// Not shown: on hover these ears stay and the line under them is the current tab's
    /// (`NotchModel.peekModule`), so the next meeting and its join button don't give way.
    func peekLine() -> AnyView { AnyView(EmptyView()) }

    func body() -> AnyView { AnyView(EmptyView()) }
    func primaryAction() {}
}
