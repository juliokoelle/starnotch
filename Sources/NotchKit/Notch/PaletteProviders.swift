import AppKit
import NotchCore
import SwiftUI

// What each module adds to the command palette. A module joins by conforming to
// `PaletteProvider`; the palette asks every shown module when it opens.

extension AgentsModule: PaletteProvider {
    /// Sessions (↵ their terminal or app, ⌘↵ the detail in the notch) and loops (↵ the loop in
    /// the notch, ⌘↵ its result or log).
    func paletteItems(_ context: PaletteContext) -> [PaletteItem] {
        let now = Date()
        let sessions = snapshot.agents.map { agent in
            let waiting = mood(of: agent, now: now) == .waiting
            return PaletteItem(
                id: "session:\(agent.id)", title: agent.displayTitle, subtitle: secondary(for: agent, now: now),
                symbol: agent.isBusy ? "terminal.fill" : "terminal", kind: .session,
                keywords: [agent.project, agent.branch ?? "", Self.toolName(of: agent.provider)],
                priority: agent.needsYou != nil ? 1 : waiting ? 0.6 : agent.isBusy ? 0.3 : 0,
                tint: agent.needsYou != nil ? Theme.waiting : nil,
                secondaryTitle: "Show in notch",
                perform: { [weak self] in self?.jump(to: agent) },
                secondary: { [weak self] in
                    context.show(.agents)
                    self?.openDetail(agent)
                })
        }
        let loops = loops.map { loop in
            let failed = loop.last?.status == .fail
            let result = loop.outboxLink ?? (failed ? Runtime.jobs?.logURL : nil)
            return PaletteItem(
                id: "loop:\(loop.name)", title: loop.displayName,
                subtitle: [phase(of: loop).word, loop.last?.note ?? ""].filter { !$0.isEmpty }.joined(separator: " · "),
                symbol: failed ? "xmark.circle" : "arrow.triangle.2.circlepath", kind: .loop,
                keywords: [loop.name], priority: failed ? 0.5 : 0, tint: failed ? Theme.critical : nil,
                secondaryTitle: result == nil ? nil : failed && loop.outboxLink == nil ? "Open the log" : "Open result",
                perform: { [weak self] in
                    context.show(.agents)
                    self?.openLoop(loop.name)
                },
                secondary: result.map { url in { NSWorkspace.shared.open(url) } })
        }
        return sessions + loops
    }
}

extension CalendarModule: PaletteProvider {
    /// Today's events still to come or under way: ↵ joins a call (or opens Calendar), ⌘↵ Calendar.
    func paletteItems(_ context: PaletteContext) -> [PaletteItem] {
        let now = Date()
        let dayEnd = Calendar.current.startOfDay(for: now).addingTimeInterval(86_400)
        let listed = meetings(dayOffset: 0)
        let events = (listed.isEmpty ? upcoming : listed).filter { $0.end > now && $0.start < dayEnd }
        return events.map { event in
            let time = "\(TimeText.clock(event.start))–\(TimeText.clock(event.end))"
            let soon = event.start.timeIntervalSince(now) < 15 * 60
            return PaletteItem(
                id: "event:\(event.id)", title: event.title,
                subtitle: [time, event.link?.provider.rawValue ?? event.location ?? ""].filter { !$0.isEmpty }.joined(separator: " · "),
                symbol: event.symbol, kind: .event, keywords: [event.calendar] + event.attendees,
                priority: soon ? 0.8 : 0.2,
                secondaryTitle: event.link != nil ? "Open Calendar" : nil,
                perform: { [weak self] in
                    if let url = event.link?.url {
                        Haptics.confirm()
                        NSWorkspace.shared.open(url)
                    } else {
                        self?.openCalendarApp()
                    }
                },
                secondary: event.link == nil ? nil : { [weak self] in self?.openCalendarApp() })
        }
    }
}

extension ToolsModule: PaletteProvider {
    /// The switched-on tools: start or stop the timer, clipboard items (↵ copy, ⌘↵ show), shelf
    /// files (↵ open, ⌘↵ in Finder).
    func paletteItems(_ context: PaletteContext) -> [PaletteItem] {
        var items: [PaletteItem] = []
        if tabs.contains(.timer) {
            let running = timer.isRunning || simple.isRunning
            items.append(PaletteItem(
                id: "tool:timer", title: running ? Localization.string("Pause timer") : timerActive ? Localization.string("Resume timer") : Localization.string("Start focus timer"),
                subtitle: timerKind.rawValue, symbol: running ? "pause.fill" : "timer", kind: .tool,
                keywords: ["pomodoro", "focus", "countdown", "stopwatch"], priority: timerActive ? 0.4 : 0,
                secondaryTitle: "Show timer",
                perform: { [weak self] in self?.startOrPause() },
                secondary: { [weak self] in
                    self?.tab = .timer
                    context.show(.tools)
                }))
            if timerActive {
                items.append(PaletteItem(id: "tool:timer-stop", title: Localization.string("Stop timer"), symbol: "stop.fill", kind: .tool,
                                         keywords: ["pomodoro", "reset"], perform: { [weak self] in self?.stopTimer() }))
            }
        }
        if tabs.contains(.clipboard) {
            for item in history.list().prefix(40) {
                let line = item.isImage ? item.imageTitle : item.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? item.text
                items.append(PaletteItem(
                    id: "clip:\(item.id.uuidString)", title: String(line.prefix(120)),
                    subtitle: item.source, symbol: item.pinned ? "pin.fill" : item.isImage ? "photo" : "doc.on.clipboard", kind: .clipboard,
                    secondaryTitle: "Show in notch",
                    perform: { [weak self] in self?.copy(item) },
                    secondary: { [weak self] in
                        self?.tab = .clipboard
                        self?.selected = item.id
                        context.show(.tools)
                    }))
            }
        }
        if tabs.contains(.shelf) {
            for url in shelf {
                items.append(PaletteItem(
                    id: "shelf:\(url.path)", title: url.lastPathComponent,
                    subtitle: url.deletingLastPathComponent().lastPathComponent, symbol: "doc", kind: .file,
                    secondaryTitle: "Show in Finder",
                    perform: { NSWorkspace.shared.open(url) },
                    secondary: { [weak self] in self?.reveal(url) }))
            }
        }
        return items
    }
}

extension SystemModule: PaletteProvider {
    /// Keep awake and dark mode, the switches of the System tab.
    func paletteItems(_ context: PaletteContext) -> [PaletteItem] {
        var items: [PaletteItem] = []
        if offersKeepAwake {
            items.append(PaletteItem(
                id: "tool:keep-awake", title: keepAwake ? Localization.string("Let the Mac sleep") : Localization.string("Keep awake"),
                subtitle: keepAwake ? Localization.string("Keep awake is on") : nil,
                symbol: keepAwake ? "cup.and.saucer.fill" : "cup.and.saucer", kind: .tool,
                keywords: ["caffeinate", "sleep", "awake", "insomnia"],
                perform: { [weak self] in self?.onToggleKeepAwake?() }))
        }
        items.append(PaletteItem(
            id: "tool:dark-mode", title: darkMode ? Localization.string("Light mode") : Localization.string("Dark mode"), symbol: darkMode ? "sun.max" : "moon", kind: .tool,
            keywords: ["appearance", "theme"],
            perform: { [weak self] in self?.toggleDarkMode() }))
        return items
    }
}

extension NowPlayingModule: PaletteProvider {
    /// Play or pause and skip, while something plays or is paused.
    func paletteItems(_ context: PaletteContext) -> [PaletteItem] {
        guard let track else { return [] }
        return [
            PaletteItem(id: "music:toggle", title: isPlaying ? Localization.string("Pause") : Localization.string("Play"), subtitle: "\(track.title) · \(track.artist)",
                        symbol: isPlaying ? "pause.fill" : "play.fill", kind: .music, keywords: ["music", "spotify"],
                        perform: { [weak self] in self?.togglePlay() }),
            PaletteItem(id: "music:next", title: Localization.string("Next track"), subtitle: track.title, symbol: "forward.fill", kind: .music,
                        keywords: ["skip", "music"], perform: { [weak self] in self?.next() }),
        ]
    }
}
