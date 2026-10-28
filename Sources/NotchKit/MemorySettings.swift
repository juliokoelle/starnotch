import AppKit
import NotchCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Tara's memory: pause it, a switch per source with its delete, the apps she never
/// records, and which AI apps can read her memory.
struct MemorySettings: View {
    @Bindable var state: AppState
    var setup: SetupCenter?
    var openSetup: () -> Void = {}
    @State private var counts: [MemorySource: Int] = [:]
    /// Whether a source holds any file at all (a feed or calendar file with no meeting left counts).
    @State private var holds: [MemorySource: Bool] = [:]
    @State private var deleting: MemorySource?
    @State private var deleted: MemorySource?

    private var privacy: MemoryPrivacy { state.settings.privacy }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            PauseRow(state: state, now: context.date)
        }
        ForEach(MemorySource.allCases, id: \.self) { source in
            sourceRow(source)
        }
        IgnoreList(state: state)
        if let setup { aiApps(setup) }
    }

    // MARK: Sources

    private func sourceRow(_ source: MemorySource) -> some View {
        let on = privacy.isOn(source)
        return HStack(alignment: .center, spacing: 12) {
            RowSymbol(name: source.symbol, active: on)
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(source.title)).font(.system(size: 14, weight: .medium))
                Text(LocalizedStringKey(source.detail)).font(.system(size: 13.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(holding(source)).font(.system(size: 13.5)).foregroundStyle(deleted == source ? Color.green : Color.secondary)
                    .monospacedDigit()
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 12)
            if canDelete(source) {
                Button("Delete…") { deleting = source }
                    .controlSize(.regular)
                    .help(Text("Delete what Tara remembers from this source"))
            }
            Toggle("", isOn: Binding(get: { on }, set: { value in
                state.settings.privacy.set(source, on: value)
            }))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(Theme.accent)
            .accessibilityLabel(Text(LocalizedStringKey(source.title)))
        }
        .padding(.vertical, 2)
        .onAppear { recount(source) }
        .confirmationDialog(Text(confirmTitle(source)), isPresented: Binding(
            get: { deleting == source }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { forget(source) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(LocalizedStringKey(Self.confirmMessage(source)))
        }
    }

    private func canDelete(_ source: MemorySource) -> Bool {
        (counts[source] ?? 0) > 0 || holds[source] == true
    }

    private func recount(_ source: MemorySource) {
        counts[source] = state.memoryCount?(source) ?? 0
        holds[source] = state.memoryHasFiles?(source) ?? false
    }

    private func forget(_ source: MemorySource) {
        let ok = state.onForgetMemory?(source) ?? false
        withAnimation(Theme.snappy) {
            recount(source)
            deleted = ok ? source : nil
        }
        Haptics.confirm()
    }

    private func holding(_ source: MemorySource) -> String {
        if deleted == source { return Localization.string("Deleted") }
        let count = counts[source] ?? 0
        switch source {
        case .meetings: return count == 1 ? Localization.string("1 meeting kept") : String(format: Localization.string("%d meetings kept"), count)
        case .captures: return count == 1 ? Localization.string("1 capture kept") : String(format: Localization.string("%d captures kept"), count)
        case .notes:
            if count == 0 { return Localization.string("No snapshot kept") }
            return count == 1 ? Localization.string("1 snapshot kept") : String(format: Localization.string("%d snapshots kept"), count)
        case .clipboard: return count == 1 ? Localization.string("1 copy, in memory only") : String(format: Localization.string("%d copies, in memory only"), count)
        case .sessions: return Localization.string("Read where each tool keeps them; Starnotch keeps no copy")
        }
    }

    private func confirmTitle(_ source: MemorySource) -> String {
        String(format: Localization.string("Delete what Tara remembers from %@?"), Localization.string(source.title))
    }

    static func confirmMessage(_ source: MemorySource) -> String {
        switch source {
        case .meetings: "Every saved meeting, its transcript and today's calendar snapshot go from this Mac. Jamie and your calendar keep their own."
        case .captures: "The captures Tara kept go. Your Markdown inbox keeps its lines."
        case .notes: "Tara's snapshots of your vault and other tools go. Your notes stay as they are."
        case .clipboard: "Everything in the clipboard history goes, pinned items too."
        case .sessions: "The scripts that reopen past sessions go. The sessions stay in each tool."
        }
    }

    // MARK: AI apps

    private func aiApps(_ setup: SetupCenter) -> some View {
        let apps = SetupItem.memoryItems.filter { setup.isSetUp($0) }.compactMap(\.appName)
        return HStack(alignment: .center, spacing: 12) {
            RowSymbol(name: "sparkles", active: !apps.isEmpty)
            VStack(alignment: .leading, spacing: 2) {
                Text("In your AI apps").font(.system(size: 14, weight: .medium))
                Text(apps.isEmpty ? Localization.string("None yet. Claude, ChatGPT and Cursor can search your memory, read only.")
                                  : apps.joined(separator: ", ") + " · " + Localization.string("read only, what's switched on above"))
                    .font(.system(size: 13.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(apps.isEmpty ? "Choose apps…" : "Change…", action: openSetup)
        }
        .padding(.vertical, 2)
    }
}

/// Paused or remembering, with the pause lengths or Resume.
private struct PauseRow: View {
    @Bindable var state: AppState
    let now: Date

    var body: some View {
        let privacy = state.settings.privacy
        let paused = privacy.isPaused(at: now)
        HStack(alignment: .center, spacing: 12) {
            RowSymbol(name: paused ? "pause.circle.fill" : "record.circle", active: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(paused ? "Paused" : "Remembering").font(.system(size: 14, weight: .semibold))
                Text(line(privacy, paused: paused)).font(.system(size: 13.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if paused {
                Button("Resume") { state.settings.privacy.resume() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Menu("Pause") {
                    ForEach(MemoryPause.allCases, id: \.self) { length in
                        Button(LocalizedStringKey(length.title)) { state.settings.privacy.pause(length, now: Date()) }
                    }
                }
                .fixedSize()
            }
        }
        .padding(.vertical, 4)
        .animation(Theme.snappy, value: paused)
    }

    private func line(_ privacy: MemoryPrivacy, paused: Bool) -> String {
        guard paused, let until = privacy.pausedUntil else {
            return Localization.string("On this Mac only. Pause it for a call or work you don't want kept; what Tara already has stays.")
        }
        if privacy.isPausedUntilResumed { return Localization.string("Nothing new is recorded until you resume.") }
        let time = until.formatted(Calendar.current.isDate(until, inSameDayAs: now) ? .dateTime.hour().minute() : .dateTime.weekday(.wide).hour().minute())
        return String(format: Localization.string("Nothing new is recorded until %@."), time)
    }
}

/// The apps Tara never records: the password apps always, and the user's own.
private struct IgnoreList: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                RowSymbol(name: "eye.slash", active: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Never recorded").font(.system(size: 14, weight: .medium))
                    Text("Password apps always: 1Password, Bitwarden, Passwords, Keychain Access and more. Add apps whose copies and windows Tara should never keep.")
                        .font(.system(size: 13.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button("Add an app…", action: pick)
            }
            ForEach(state.settings.privacy.ignoredApps, id: \.bundleID) { app in
                HStack(spacing: 10) {
                    AppIconImage(bundleID: app.bundleID)
                    Text(app.name).font(.system(size: 14))
                    Spacer()
                    Button {
                        withAnimation(Theme.snappy) { state.settings.privacy.unignore(app.bundleID) }
                    } label: {
                        Image(systemName: "minus.circle.fill").font(.system(size: 15)).foregroundStyle(.secondary)
                            .frame(width: 28, height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(Text("Record this app again"))
                    .accessibilityLabel(Text("Remove \(app.name) from the list"))
                }
                .padding(.leading, 40)
                .transition(.opacity)
            }
        }
        .padding(.vertical, 2)
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = Localization.string("Never record")
        guard panel.runModal() == .OK else { return }
        withAnimation(Theme.snappy) {
            for url in panel.urls {
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
                let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                state.settings.privacy.ignore(IgnoredApp(bundleID: id, name: name))
            }
        }
    }
}

private struct AppIconImage: View {
    let bundleID: String

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
        } else {
            Image(systemName: "app.dashed").frame(width: 20, height: 20).foregroundStyle(.secondary)
        }
    }
}

/// Recordings: Settings › Tara's memory on its own (`--preview memory-settings[:paused]`).
@MainActor
enum MemorySettingsPreview {
    private static var window: NSWindow?

    static func show(state: AppState, setup: SetupCenter?, paused: Bool) {
        if paused { state.settings.privacy.pause(.oneHour, now: Date()) }
        state.settings.privacy.set(.clipboard, on: false)
        state.settings.privacy.ignore(IgnoredApp(bundleID: "com.apple.Notes", name: "Notes"))
        state.memoryCount = { source in
            switch source {
            case .meetings: 14
            case .captures: 23
            case .notes: 1
            case .clipboard: 0
            case .sessions: 0
            }
        }
        let view = Form {
            Section {
                MemorySettings(state: state, setup: setup)
            } header: {
                Text("Tara's memory")
            } footer: {
                Text(MemorySettings.footer).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = "\(Brand.displayName) Settings"
        window.styleMask = [.titled, .closable]
        window.center()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

extension MemorySettings {
    static let footer: LocalizedStringKey = "Everything Tara remembers stays on this Mac, in the app's folder. A pause stops recording; a source that's off is also left out of Tara's answers and your AI apps. Delete removes Starnotch's copy only: your vault, Jamie and your calendar keep theirs."
}
