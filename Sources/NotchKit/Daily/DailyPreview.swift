import AppKit
import NotchCore
import SwiftUI

/// Lines for sneaks, in the interface language.
enum DailyText {
    /// "Readiness 80 · Sleep 84", "Recovery 72 % · Sleep 91 %".
    static func health(_ day: HealthDay) -> String {
        var parts: [String] = []
        if let readiness = day.readiness {
            let score = "\(readiness)"
            parts.append(String(localized: "Readiness \(score)"))
        }
        if let recovery = day.recovery {
            let percent = "\(recovery) %"
            parts.append(String(localized: "Recovery \(percent)"))
        }
        if let sleep = day.sleep {
            // WHOOP scores sleep in percent, Oura with a plain score.
            let score = day.source == .whoop ? "\(sleep) %" : "\(sleep)"
            parts.append(String(localized: "Sleep \(score)"))
        }
        return parts.joined(separator: " · ")
    }

    /// "H 19° L 11°" ("H 19° T 11°" in German).
    static func range(_ report: WeatherReport) -> String {
        let high = WeatherReport.degrees(report.high), low = WeatherReport.degrees(report.low)
        return String(localized: "H \(high) L \(low)")
    }

    /// The next hours in one sentence: when rain or snow is likely, else that it stays dry.
    static func outlook(_ report: WeatherReport, now: Date) -> String {
        let hours = report.upcoming(from: now, count: 8)
        guard let wet = hours.first(where: { ($0.precipitation ?? 0) >= 50 }) else {
            return String(localized: "Dry for the next hours")
        }
        let snow = [WeatherCondition.snow, .snowShowers].contains(wet.condition)
        if wet.time <= now { return snow ? String(localized: "Snow likely now") : String(localized: "Rain likely now") }
        let clock = TimeText.clock(wet.time)
        return snow ? String(localized: "Snow likely from \(clock)") : String(localized: "Rain likely from \(clock)")
    }
}

/// `--preview daily-…`: the daily tools with made-up weather, scores and notes.
///
///     daily-calendar        the calendar with the chip in its header
///     daily-card            the day card: weather, work day, last night (Oura)
///     daily-card-whoop      the same with WHOOP's recovery
///     daily-card-weather    only the weather tool on
///     daily-card-empty      nothing set up yet
///     daily-ears            weather and progress beside the notch at rest
///     daily-ears-weather    the weather alone beside the notch
///     daily-ears-peek       hovering them: the ears stay, the line is the tab's
///     daily-notes           notes in the Tools tab
///     daily-morning         the morning line
///     daily-settings        Settings with the Daily section
enum DailyPreview {
    static let names = ["daily-calendar", "daily-card", "daily-card-whoop", "daily-card-weather", "daily-card-empty",
                        "daily-ears", "daily-ears-weather", "daily-ears-peek", "daily-notes", "daily-morning", "daily-settings"]

    static func handles(_ name: String) -> Bool { names.contains(name) }

    /// Before the tools are applied: made-up data for every preview and the sample mode.
    @MainActor
    static func prepare(_ name: String?, store: DailyStore) {
        let all: Set<ToolFeature> = [.weather, .dayProgress, .notes, .health]
        // A work day that is running whenever the preview is taken.
        let minute = Calendar.current.component(.hour, from: Date()) * 60 + Calendar.current.component(.minute, from: Date())
        var settings = DailySettings(workDay: WorkDay(start: max(0, minute - 5 * 60 - 10), end: min(24 * 60 - 1, minute + 3 * 60 + 20), weekends: true))
        var features = all
        switch name {
        case "daily-card-whoop": settings.healthSource = .whoop
        case "daily-card-weather": features = [.weather]
        case "daily-ears", "daily-ears-peek":
            settings.weatherInEar = true
            settings.progressInEar = true
        case "daily-ears-weather":
            settings.weatherInEar = true
            features = [.weather]
        default: settings.healthSource = .oura
        }
        store.usePreview(on: features, settings: settings)
        if name == "daily-card-empty" { store.clearPreviewData() }
    }

    @MainActor
    static func run(_ name: String, store: DailyStore, notch: NotchController, tools: ToolsModule, agents: AgentsModule) {
        switch name {
        case "daily-ears", "daily-ears-weather", "daily-ears-peek":
            // Nothing else asks for the ears.
            agents.usePreview(AgentSnapshot())
            if name == "daily-ears-peek" {
                // The sample music pauses, or its ears would take the hover.
                notch.model.modules.compactMap { $0 as? NowPlayingModule }.first?.togglePlay()
                notch.tourPeek()
            }
        case "daily-calendar":
            notch.expand(.calendar, pinned: true)
        case "daily-card", "daily-card-whoop", "daily-card-weather", "daily-card-empty":
            notch.expand(.calendar, pinned: true)
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                withAnimation(Theme.snappy) { store.cardShown = true }
            }
        case "daily-notes":
            tools.tab = .notes
            notch.expand(.tools, pinned: true)
        case "daily-morning":
            if let health = store.health { _ = store.onMorningLine?(health, store.shownWeather) }
        default:
            break
        }
    }

    @MainActor private static var settingsWindow: NSWindow?

    /// The Daily section alone in a window, for screenshots (the full Settings form scrolls).
    @MainActor
    static func showSettings(state: AppState) {
        let view = Form { DailySettingsSection(state: state) }.formStyle(.grouped).frame(width: 560, height: 720)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 720), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: view)
        window.title = "Daily"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.setFrameTopLeftPoint(NSPoint(x: 476, y: (NSScreen.main?.frame.maxY ?? 982) - 60))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        settingsWindow = window
    }
}
