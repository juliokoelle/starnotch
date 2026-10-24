import AppKit
import NotchCore
import SwiftUI

/// Recordings of the calendar (agenda with the day band) and Today with sample data:
///
///     --preview cal | cal:compact | cal:peek | cal:keys | cal:note
///     --preview today | today:compact | today:peek | today:hover
///     --preview agenda-tour    both, about 26 s, then quits
///
/// The clock reads 12:18 (the design review is at 12:30). Nothing is read or written; without
/// `--preview` the same modules run on EventKit and the connectors.
@MainActor
final class AgendaPreview {
    static func handles(_ name: String?) -> Bool {
        guard let name else { return false }
        return name.hasPrefix("cal") || name.hasPrefix("today") || name == "agenda-tour"
    }

    let agenda: AgendaModule
    let today: TodayModule
    private(set) var notch: NotchController?

    init() {
        R5Clock.set(hour: 12, minute: 18)
        let samples = SampleConnector()
        agenda = AgendaModule(variant: .b, people: samples)
        today = TodayModule(provider: samples, agenda: agenda)
    }

    func run(_ name: String, notch: NotchController, agents: AgentsModule) {
        self.notch = notch
        agents.usePreview(PreviewDirector.snapshot(agentsActive: false))
        Task { await play(name) }
    }

    private func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    private func play(_ name: String) async {
        guard let notch else { return }
        await pause(0.8)
        let parts = name.split(separator: ":").map(String.init)
        let base = parts[0], state = parts.count > 1 ? parts[1] : "expanded"
        if base == "agenda-tour" { await tour(); return }
        let module: ModuleKind = base.hasPrefix("cal") ? .calendar : .today
        if module == .today { today.ambientOverride = 35 }
        switch state {
        case "saturday", "saturday-select":
            // A weekend day without meetings at 08:00; with "-select" an event picked.
            R5Clock.set(hour: 8, minute: 0)
            agenda.mockEvents = AgendaSamples.saturday(R5Clock.now())
            notch.expand(module, pinned: true)
            if state == "saturday-select" {
                await pause(0.8)
                if let event = agenda.events.first(where: { $0.id == "hack" }) { agenda.select(event) }
            }
        case "compact": break
        case "peek": notch.tourPeek()
        case "keys":
            notch.expand(module, pinned: true)
            await pause(0.6)
            for _ in 0..<3 { agenda.step(1); await pause(0.35) }
        case "hover":
            notch.expand(module, pinned: true)
            await pause(0.6)
            withAnimation(Theme.snappy) { today.selectedID = today.tasks.first?.id }
        case "note":
            R5Clock.set(hour: 13, minute: 4)
            await pause(0.3)
            noteSneak()
        default:
            notch.expand(module, pinned: true)
        }
    }

    /// A meeting note landed after the call.
    func noteSneak() {
        notch?.sneak(Sneak(visual: .symbol("doc.text", tint: .accent), title: "Note ready",
                           detail: "Design review · 2 tasks", duration: 3.4),
                     key: "agenda.note")
    }

    /// The calendar and Today, about 26 s.
    private func tour() async {
        guard let notch else { return }
        await pause(1.0)
        notch.tourPeek()
        await pause(1.8)
        notch.expand(.calendar, pinned: true)
        await pause(2.8)
        for _ in 0..<3 { agenda.step(1); await pause(0.7) }
        await pause(0.6)
        withAnimation(Theme.snappy) { agenda.selectedID = nil }
        await pause(1.0)
        notch.collapse()
        await pause(0.9)
        R5Clock.set(hour: 13, minute: 4)
        noteSneak()
        await pause(3.4)
        R5Clock.set(hour: 12, minute: 18)

        // Today: overview; walking the rows shows where each one goes (↗ opens it).
        notch.expand(.today, pinned: true)
        await pause(2.4)
        for item in today.actionable.prefix(4) {
            withAnimation(Theme.snappy) { today.selectedID = item.id }
            await pause(0.8)
        }
        await pause(0.8)
        withAnimation(Theme.snappy) { notch.model.module = .calendar }
        await pause(1.8)
        notch.collapse()
        await pause(1.0)
        NSApp.terminate(nil)
    }
}
