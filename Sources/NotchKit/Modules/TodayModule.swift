import AppKit
import NotchCore
import Observation
import SwiftUI

/// Today from a `TodayProvider` connector: one hero item ("Up next", or the next meeting), the
/// main list, follow-ups, confirmations, a brief and a few counters. Read only: nothing is checked
/// off in the notch; every row opens its place in the connector's own app.
@MainActor
@Observable
final class TodayModule: NotchModule {
    struct Item: Identifiable, Equatable {
        enum Kind: Int, CaseIterable { case meeting, followUp, task, confirm }
        var id: String
        var kind: Kind
        var title: String
        var detail: String = ""
        var date: String?
        var people: [String] = []
        /// Where a click goes.
        var url: URL?
        var help: String = ""
        var group: String = ""
        var notes: [String] = []

        init(id: String, kind: Kind, title: String, detail: String = "", date: String? = nil,
             people: [String] = [], url: URL? = nil, help: String = "", group: String = "", notes: [String] = []) {
            self.group = group
            self.notes = notes
            self.id = id
            self.kind = kind
            self.title = title
            self.detail = detail
            self.date = date
            self.people = people
            self.url = url
            self.help = help
        }

        init(_ item: TodayItem) {
            let kind: Kind = switch item.kind {
            case .task: .task
            case .followUp: .followUp
            case .confirm: .confirm
            }
            self.init(id: item.id, kind: kind, title: item.title, detail: item.detail, date: item.date,
                      people: item.people, url: item.url, help: item.help, group: item.group, notes: item.notes)
        }
    }

    let kind = ModuleKind.today
    let symbol = ModuleSymbols.symbol(.today)
    let provider: any TodayProvider
    let agenda: AgendaModule

    private(set) var feed = TodayFeed()
    private(set) var tasks: [Item] = []
    private(set) var followUps: [Item] = []
    private(set) var confirmations: [Item] = []
    var selectedID: String?
    /// Ear priority in the preview.
    var ambientOverride = 0
    /// "Prepare" switches to the calendar.
    @ObservationIgnored var onOpenCalendar: (() -> Void)?

    init(provider: any TodayProvider, agenda: AgendaModule) {
        self.provider = provider
        self.agenda = agenda
        load()
    }

    var today: String { R5Clock.day(R5Clock.now()) }

    private func load() {
        feed = provider.today(now: R5Clock.now())
        tasks = feed.now.map(Item.init)
        followUps = feed.followUps.map(Item.init)
        confirmations = feed.confirmations.map(Item.init)
    }

    /// Asks the connector again when the panel opens.
    func reload() {
        withAnimation(Theme.snappy) { load() }
    }

    /// The next meeting within the hour, with what is open with its people.
    var meetingHero: Item? {
        guard let next = agenda.nextMeeting, next.start.timeIntervalSince(R5Clock.now()) < 3600 else { return nil }
        let titles = Set(tasks.map(\.title))
        let open = agenda.prep(for: next).items.first { $0.source == .task && titles.contains($0.title) }
        return Item(id: "meeting-\(next.id)", kind: .meeting, title: next.title,
                    detail: open.map { "Open: \($0.title)" } ?? "", date: open?.date, people: next.attendees)
    }

    /// Variant A's hero: the meeting if it is close, else the first task.
    var hero: Item? { meetingHero ?? tasks.first }

    var dueFollowUps: Int { followUps.filter { $0.date.map { $0 <= today } ?? false }.count }
    var openCount: Int { tasks.count + followUps.count + confirmations.count }

    /// Rows the keyboard walks through in variant A.
    var actionable: [Item] { tasks + followUps + confirmations }

    func openHome() { if let url = feed.home?.url { NSWorkspace.shared.open(url) } }

    func open(_ link: TodayLink?) { if let url = link?.url { NSWorkspace.shared.open(url) } }

    /// The item whose detail card shows.
    var detail: Item?

    /// A row: its detail card in the notch (the link to its place is on the card).
    func open(_ item: Item) {
        Haptics.tick()
        if item.kind == .meeting {
            onOpenCalendar?()
        } else {
            withAnimation(Theme.snappy) { detail = item }
        }
    }

    func openExternally(_ item: Item) {
        if let url = item.url ?? feed.home?.url { NSWorkspace.shared.open(url) }
    }

    var holdsOpen: Bool { detail != nil }

    func handleBack() -> Bool {
        guard detail != nil else { return false }
        withAnimation(Theme.snappy) { detail = nil }
        return true
    }

    // MARK: NotchModule

    var count: Int? { tasks.isEmpty ? nil : tasks.count }
    var ambientPriority: Int { ambientOverride }

    func setExpanded(_ expanded: Bool) {
        if expanded { reload() }
    }

    func leadingEar(peek: Bool) -> AnyView {
        AnyView(Image(systemName: "checklist")
            .font(.system(size: peek ? 13 : 12, weight: .semibold))
            .foregroundStyle(Theme.textBody))
    }

    func trailingEar(peek: Bool) -> AnyView {
        AnyView(HStack(spacing: 5) {
            Text("\(tasks.count)")
                .font(Theme.font(peek ? 13 : 12, .semibold).monospacedDigit())
                .foregroundStyle(Theme.textBody)
                .contentTransition(.numericText())
            if dueFollowUps > 0 {
                Circle().fill(Theme.waiting).frame(width: 6, height: 6)
                    .help("Follow up today")
            }
        })
    }

    func peekLine() -> AnyView {
        AnyView(HStack(spacing: 8) {
            if let hero {
                let label = Text("Up next").font(Theme.font(12, .semibold)).foregroundStyle(Theme.accent)
                let title = Text(hero.title).font(Theme.font(13, .semibold)).foregroundStyle(Theme.textPrimary)
                let countdown: Text? = hero.kind == .meeting ? agenda.nextMeeting.map {
                    Text(R5Clock.countdown(start: $0.start, end: $0.end, now: R5Clock.now()))
                        .font(Theme.font(12.5).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                } : nil
                // Narrow peek: the counts go first, then the label; the title truncates.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        label.fixedSize(); title.fixedSize(); countdown?.fixedSize()
                        Spacer(minLength: 6)
                        Text("\(tasks.count) now · \(dueFollowUps) to follow up")
                            .font(Theme.font(12)).foregroundStyle(Theme.textSecondary).fixedSize()
                    }
                    HStack(spacing: 8) { label.fixedSize(); title; countdown?.fixedSize(); Spacer(minLength: 0) }
                    HStack(spacing: 8) { title; Spacer(minLength: 0) }
                }
            }
        }
        .lineLimit(1))
    }

    func body() -> AnyView { AnyView(TodayBody(module: self)) }

    /// Return opens the selected row (or the first).
    func primaryAction() {
        if let item = actionable.first(where: { $0.id == selectedID }) ?? actionable.first { open(item) }
    }

    /// ↑↓ walk the rows.
    func handleKey(_ press: KeyPress) -> Bool {
        switch press.key {
        case .upArrow, .downArrow:
            let list = actionable
            guard !list.isEmpty else { return true }
            let index = list.firstIndex { $0.id == selectedID } ?? -1
            let next = min(max(index + (press.key == .downArrow ? 1 : -1), 0), list.count - 1)
            Haptics.tick()
            withAnimation(Theme.snappy) { selectedID = list[next].id }
            return true
        default:
            return false
        }
    }
}

// MARK: Overview with a hero

private struct TodayBody: View {
    let module: TodayModule

    var body: some View {
        ZStack {
            if let item = module.detail {
                TodayDetailCard(module: module, item: item)
                    .transition(.blurSlide(x: 18))
            } else {
                overview.transition(.blurSlide(y: -10))
            }
        }
    }

    private var overview: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 10) {
                if let hero = module.hero { HeroCard(module: module, item: hero) }
                NotchCard(padding: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        SectionLabel(title: module.feed.nowTitle, trailing: "\(module.tasks.count)")
                            .padding(.horizontal, 6)
                            .padding(.bottom, 4)
                        if module.tasks.isEmpty {
                            Text(module.feed.emptyText)
                                .font(Theme.font(12.5)).foregroundStyle(Theme.textSecondary).padding(.horizontal, 6)
                        }
                        // The list scrolls inside the panel instead of stopping at four.
                        ScrollView(.vertical) {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(module.tasks) { item in
                                    ItemRow(module: module, item: item)
                                        .transition(.blurSlide(y: -4, scale: 0.98))
                                }
                            }
                        }
                        .scrollIndicators(.never)
                    }
                }
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 8) {
                // Brief, follow-ups and confirmations scroll; the footer stays put.
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 12) {
                        if let brief = module.feed.brief { BriefCard(brief: brief) }
                        VStack(alignment: .leading, spacing: 4) {
                            SectionLabel(title: module.feed.followUpTitle)
                            ForEach(module.followUps) { item in
                                ItemRow(module: module, item: item, compact: true)
                                    .transition(.blurSlide(y: -4, scale: 0.98))
                            }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            if module.confirmations.isEmpty {
                                if let link = module.feed.confirmationsLink {
                                    LinkRow(title: link.title, detail: link.detail) { module.open(link) }
                                }
                            } else {
                                SectionLabel(title: module.feed.confirmTitle, trailing: "\(module.confirmations.count)")
                                ForEach(module.confirmations.prefix(2)) { item in
                                    ItemRow(module: module, item: item, compact: true)
                                        .transition(.blurSlide(y: -4, scale: 0.98))
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.never)
                Footer(module: module)
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)
            .frame(width: 232)
        }
    }
}

private struct HeroCard: View {
    let module: TodayModule
    let item: TodayModule.Item

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = R5Clock.now(context.date)
            NotchCard(padding: 14) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Up next").font(Theme.font(11.5, .semibold)).foregroundStyle(Theme.accent)
                        Text(item.title).font(Theme.font(16, .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        if item.kind == .meeting, let next = module.agenda.nextMeeting {
                            HStack(spacing: 5) {
                                Text(TimeText.clock(next.start)).monospacedDigit()
                                Text("·")
                                Text(R5Clock.countdown(start: next.start, end: next.end, now: now)).contentTransition(.numericText())
                                if let link = next.link { Text("·"); Text(link.provider.displayName) }
                            }
                            .font(Theme.font(12)).foregroundStyle(Theme.textSecondary)
                        }
                        if !item.detail.isEmpty {
                            HStack(spacing: 6) {
                                Circle().fill(Theme.waiting).frame(width: 5, height: 5)
                                Text(item.detail).foregroundStyle(Theme.textBody)
                                if let date = item.date {
                                    Text(R5Clock.due(date, today: module.today)).foregroundStyle(Theme.waiting)
                                }
                            }
                            .font(Theme.font(12))
                            .lineLimit(1)
                            .padding(.top, 2)
                        }
                    }
                    Spacer(minLength: 6)
                    VStack(alignment: .trailing, spacing: 10) {
                        if item.kind == .meeting {
                            AvatarStack(names: item.people, size: 24)
                            QuietLink(title: "Prepare", symbol: "arrow.right") { module.onOpenCalendar?() }
                        }
                    }
                }
            }
            .frame(height: 102)
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1)
            )
            .shadow(color: Theme.accent.opacity(0.22), radius: 16)
        }
    }
}

/// One task or follow-up in full: title, detail, notes, due, where it sits, who it's with, and
/// the way to its place (the hub opens a task scrolled into view and expanded).
private struct TodayDetailCard: View {
    let module: TodayModule
    let item: TodayModule.Item

    var body: some View {
        NotchCard(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Button { _ = module.handleBack() } label: {
                        Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary).frame(width: 24, height: 24).contentShape(Rectangle())
                    }
                    .buttonStyle(PressScale())
                    .help("Back (Esc)")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.kind == .followUp ? "Follow up" : item.kind == .confirm ? "Confirm" : "Task")
                            .font(Theme.font(11.5, .semibold)).foregroundStyle(Theme.accent)
                        Text(item.title).font(Theme.font(16, .semibold)).foregroundStyle(Theme.textPrimary)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            if let date = item.date {
                                Text(R5Clock.due(date, today: module.today))
                                    .foregroundStyle(R5Clock.isSoon(date, today: module.today) ? Theme.waiting : Theme.textSecondary)
                            }
                            if !item.group.isEmpty { Text(item.group).foregroundStyle(Theme.textSecondary) }
                        }
                        .font(Theme.font(12))
                    }
                    Spacer(minLength: 8)
                    if item.url != nil || module.feed.home != nil {
                        Button { module.openExternally(item) } label: {
                            HStack(spacing: 4) {
                                Text("Open in \(module.feed.home?.title ?? "app")")
                                Image(systemName: "arrow.up.right").font(.system(size: 9.5, weight: .semibold))
                            }
                            .font(Theme.font(12.5, .semibold))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(PressScale())
                        .help(item.help.isEmpty ? "Open it where it lives" : item.help)
                    }
                }
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 8) {
                        if !item.detail.isEmpty {
                            Text(item.detail).font(Theme.font(12.5)).foregroundStyle(Theme.textBody)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(Array(item.notes.enumerated()), id: \.offset) { _, note in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("–").foregroundStyle(Theme.textTertiary)
                                Text(note).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                            }
                            .font(Theme.font(12))
                        }
                        if !item.people.isEmpty {
                            HStack(spacing: 6) {
                                AvatarStack(names: item.people, size: 20)
                                Text(item.people.joined(separator: ", ")).font(Theme.font(12)).foregroundStyle(Theme.textSecondary)
                            }
                            .padding(.top, 2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 34)
                }
                .scrollIndicators(.never)
            }
        }
    }
}

private struct BriefCard: View {
    let brief: TodayBrief

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(title: brief.title, trailing: brief.time.isEmpty ? nil : brief.time)
            Text(brief.text)
                .font(Theme.font(12))
                .foregroundStyle(Theme.textBody)
                .lineLimit(3)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct Footer: View {
    let module: TodayModule

    var body: some View {
        HStack(spacing: 12) {
            ForEach(module.feed.counters, id: \.label) { counter in
                Button { if let url = counter.url ?? module.feed.home?.url { NSWorkspace.shared.open(url) } } label: {
                    HStack(spacing: 4) {
                        Text(counter.label).foregroundStyle(Theme.textSecondary)
                        Text("\(counter.value)").foregroundStyle(Theme.textPrimary).monospacedDigit()
                    }
                }
                .buttonStyle(PressScale())
                .help(counter.help)
            }
            Spacer()
            if let home = module.feed.home {
                QuietLink(title: home.title) { module.openHome() }
            }
        }
        .font(Theme.font(12, .medium))
    }
}

/// One row; the whole row opens the item, a quiet ↗ on hover says so.
private struct ItemRow: View {
    let module: TodayModule
    let item: TodayModule.Item
    var compact = false
    @State private var hovering = false

    var body: some View {
        let selected = module.selectedID == item.id
        let soon = item.date.map { R5Clock.isSoon($0, today: module.today) } ?? false
        Button { module.open(item) } label: {
            HStack(spacing: 8) {
                if item.kind == .followUp, let person = item.people.first {
                    InitialsAvatar(name: person, size: 18)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(Theme.font(compact ? 12 : 12.5, .medium))
                        .foregroundStyle(Theme.textPrimary)
                    if compact, item.kind == .confirm {
                        Text(item.detail).font(Theme.font(11)).foregroundStyle(Theme.textTertiary)
                    }
                }
                Spacer(minLength: 4)
                if let date = item.date {
                    Text(R5Clock.due(date, today: module.today))
                        .font(Theme.font(11.5).monospacedDigit())
                        .foregroundStyle(soon ? Theme.waiting : Theme.textSecondary)
                }
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .opacity(hovering || selected ? 1 : 0)
                    .frame(width: 12)
            }
            .lineLimit(1)
            .padding(.horizontal, compact ? 0 : 6)
            .frame(height: compact ? (item.kind == .confirm ? 32 : 24) : 30)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(selected ? 0.08 : hovering ? 0.05 : 0))
                    .padding(.horizontal, compact ? -6 : 0)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
        .help(item.help)
    }
}

/// A plain link row into the connector's app.
private struct LinkRow: View {
    let title: String
    let detail: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(Theme.font(12, .medium)).foregroundStyle(Theme.textSecondary)
                Text(detail).font(Theme.font(12)).foregroundStyle(Theme.textTertiary)
                Spacer()
                Image(systemName: "arrow.up.right").font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary).opacity(hovering ? 1 : 0.5)
            }
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .onHover { hovering = $0 }
    }
}
