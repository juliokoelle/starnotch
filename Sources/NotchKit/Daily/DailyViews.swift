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

/// The day at a glance: the weather by the hour, how much of the work day is done, and last
/// night's sleep and readiness. It replaces the agenda until Back or Esc.
struct DailyCard: View {
    let store: DailyStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button { withAnimation(Theme.snappy) { store.cardShown = false } } label: {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressScale())
                .help("Back (Esc)")
                Text(R5Clock.longDay(store.now)).font(Theme.font(13.5, .semibold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                if store.isOn(.weather), let place = store.shownWeather?.place, !place.isEmpty {
                    Label(place, systemImage: store.settings.place == nil ? "location.fill" : "mappin")
                        .font(Theme.font(11.5)).foregroundStyle(Theme.textTertiary)
                        .labelStyle(.titleAndIcon)
                }
            }
            .frame(height: 28)
            HStack(spacing: 8) {
                if store.isOn(.weather) { WeatherPanel(store: store) }
                if store.isOn(.dayProgress) || store.isOn(.health) {
                    VStack(spacing: 8) {
                        if store.isOn(.dayProgress) { DayPanel(store: store) }
                        if store.isOn(.health) { HealthPanel(store: store) }
                    }
                    .frame(width: store.isOn(.weather) ? 196 : nil)
                }
            }
        }
        .padding(.top, 2)
    }
}

private struct WeatherPanel: View {
    let store: DailyStore

    var body: some View {
        NotchCard(padding: 14) {
            if let weather = store.shownWeather {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: weather.symbol).symbolRenderingMode(.hierarchical)
                            .font(.system(size: 30, weight: .regular))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 40)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(WeatherReport.degrees(weather.temperature))
                                .font(Theme.font(28, .semibold).monospacedDigit()).foregroundStyle(Theme.textPrimary)
                            HStack(spacing: 6) {
                                Text(LocalizedStringKey(weather.condition.title))
                                Text(DailyText.range(weather)).monospacedDigit()
                            }
                            .font(Theme.font(12)).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer(minLength: 0)
                        if store.weatherStatus == .offline {
                            Text("Offline, from \(TimeText.clock(weather.fetched))")
                                .font(Theme.font(10.5)).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    Text(DailyText.outlook(weather, now: store.now))
                        .font(Theme.font(12)).foregroundStyle(Theme.textBody)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    HStack(spacing: 0) {
                        ForEach(Array(weather.upcoming(from: store.now, count: 8).enumerated()), id: \.offset) { index, hour in
                            VStack(spacing: 7) {
                                Text(index == 0 ? String(localized: "Now") : hour.time.formatted(.dateTime.hour(.twoDigits(amPM: .omitted))))
                                    .font(Theme.font(10.5, .medium)).foregroundStyle(index == 0 ? Theme.textBody : Theme.textTertiary)
                                Image(systemName: hour.condition.symbol(isDay: hour.isDay)).symbolRenderingMode(.hierarchical)
                                    .font(.system(size: 15)).foregroundStyle(Theme.textBody)
                                    .frame(height: 20)
                                Text(WeatherReport.degrees(hour.temperature))
                                    .font(Theme.font(13, .medium).monospacedDigit()).foregroundStyle(Theme.textPrimary)
                                Text(hour.precipitation.map { $0 >= 20 ? "\($0) %" : " " } ?? " ")
                                    .font(Theme.font(10).monospacedDigit()).foregroundStyle(Theme.accent)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            } else {
                DailyEmpty(symbol: "cloud.sun", title: "Weather", text: weatherHint)
            }
        }
        // Open-Meteo's data is CC BY 4.0; Settings › Daily has the links.
        .help("Weather data by Open-Meteo.com, CC BY 4.0")
    }

    private var weatherHint: String {
        switch store.weatherStatus {
        case .needsPlace: store.locationDenied ? String(localized: "Location is off for \(Brand.bundleName). Type a city in Settings › Daily.")
            : String(localized: "No location yet. Type a city in Settings › Daily.")
        case .offline: String(localized: "Offline. The weather comes back with the connection.")
        default: String(localized: "Looking up the weather…")
        }
    }
}

private struct DayPanel: View {
    let store: DailyStore

    var body: some View {
        let status = DayStatus(store.workDay, now: store.now)
        NotchCard(padding: 12) {
            HStack(spacing: 12) {
                ZStack {
                    DayRing(progress: status.progress, size: 46, lineWidth: 4.5)
                    Text(status.isRunning ? "\(Int((status.progress * 100).rounded(.down)))" : status.progress >= 1 ? "✓" : "–")
                        .font(Theme.font(13, .semibold).monospacedDigit()).foregroundStyle(Theme.textPrimary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Work day").font(Theme.font(11.5, .semibold)).foregroundStyle(Theme.textSecondary)
                    Text(status.line).font(Theme.font(12.5, .medium)).foregroundStyle(Theme.textPrimary)
                    Text("\(WorkDay.clock(status.day.start)) – \(WorkDay.clock(status.day.end))")
                        .font(Theme.font(11).monospacedDigit()).foregroundStyle(Theme.textTertiary)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
    }
}

private struct HealthPanel: View {
    let store: DailyStore

    var body: some View {
        NotchCard(padding: 12) {
            if let health = store.health, !health.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Last night").font(Theme.font(11.5, .semibold)).foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text(health.source.title).font(Theme.font(10.5)).foregroundStyle(Theme.textTertiary)
                    }
                    HStack(alignment: .top, spacing: 14) {
                        if let headline = health.headline {
                            metric(LocalizedStringKey(health.headlineTitle), value: headline, unit: health.recovery != nil ? "%" : nil,
                                   level: HealthDay.level(headline, source: health.source))
                        }
                        if let sleep = health.sleep {
                            metric("Sleep", value: sleep, unit: health.source == .whoop ? "%" : nil,
                                   level: HealthDay.sleepLevel(sleep, source: health.source))
                        }
                        Spacer(minLength: 0)
                    }
                }
            } else {
                DailyEmpty(symbol: "heart", title: "Sleep and recovery", text: healthHint, compact: true)
            }
        }
    }

    private func metric(_ title: LocalizedStringKey, value: Int, unit: String?, level: HealthDay.Level) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text("\(value)").font(Theme.font(20, .semibold).monospacedDigit()).foregroundStyle(Theme.textPrimary)
                if let unit { Text(unit).font(Theme.font(11, .medium)).foregroundStyle(Theme.textSecondary) }
            }
            HStack(spacing: 4) {
                Circle().fill(level == .good ? Theme.ok : level == .fair ? Theme.waiting : Theme.critical).frame(width: 5, height: 5)
                Text(title).font(Theme.font(11)).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var healthHint: String {
        switch store.healthStatus {
        case .failed(let message): message
        case .loading: "Fetching last night…"
        default: store.settings.healthSource == nil ? "Pick Oura or WHOOP in Settings › Daily." : "Connect it in Settings › Daily."
        }
    }
}

private struct DailyEmpty: View {
    let symbol: String
    let title: String
    let text: String
    var compact = false

    var body: some View {
        VStack(spacing: compact ? 4 : 8) {
            if !compact {
                Image(systemName: symbol).font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            }
            Text(LocalizedStringKey(title)).font(Theme.font(12.5, .semibold)).foregroundStyle(Theme.textPrimary)
            Text(LocalizedStringKey(text)).font(Theme.font(11.5)).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
