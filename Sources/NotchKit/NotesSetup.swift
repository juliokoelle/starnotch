import AppKit
import NotchCore
import SwiftUI

/// Picking the notes folder (`VaultConnector`), shared by onboarding (one row) and Settings ›
/// Notes (the folder and its files). A pick guesses the files from what is there; each one can be
/// changed after. config.toml's `[connectors.vault]` wins, and Settings then only shows it.
@MainActor
@Observable
final class VaultSetup {
    enum Field { case tasks, inbox }

    /// Previews show this vault instead of the real one, and nothing is saved.
    static var preview: VaultConnector?

    @ObservationIgnored let connector: VaultConnector?
    @ObservationIgnored let persists: Bool
    /// After a folder is picked (Today goes on).
    @ObservationIgnored var onConnected: (() -> Void)?
    private(set) var folder: URL?
    private(set) var layout = VaultLayout()
    private(set) var openTasks = 0
    private(set) var hasDailyNote = false

    init(persists: Bool) {
        connector = Self.preview ?? Runtime.vault
        self.persists = persists && Self.preview == nil
        refresh()
    }

    /// This build has the notes connector.
    var isAvailable: Bool { connector != nil }
    var isConnected: Bool { folder != nil }
    var isFromConfig: Bool { connector?.isFromConfig ?? false }
    var name: String { folder?.lastPathComponent ?? "" }

    func refresh() {
        guard let connector, connector.isConfigured else {
            folder = nil
            layout = VaultLayout()
            openTasks = 0
            hasDailyNote = false
            return
        }
        folder = connector.folder
        layout = connector.layout
        openTasks = connector.openTasks().count
        hasDailyNote = connector.dailyURL(for: Date()).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = Localization.string("Use this folder")
        panel.message = Localization.string("Your notes: an Obsidian vault or any folder of Markdown files")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        connect(url)
    }

    /// Saves the folder with the files found in it.
    func connect(_ url: URL) {
        let found = VaultDetect.detect(in: url)
        save { defaults in
            defaults.set(url.path, forKey: VaultConnector.Key.folder)
            Self.set(found.tasks, VaultConnector.Key.tasks, in: defaults)
            Self.set(found.daily, VaultConnector.Key.daily, in: defaults)
            Self.set(found.inbox, VaultConnector.Key.inbox, in: defaults)
            // A run log among the notes feeds the loops, unless one is picked already.
            if let loops = found.loops, defaults.string(forKey: RunLogConnector.defaultsKey) == nil {
                defaults.set(url.appending(path: loops).path, forKey: RunLogConnector.defaultsKey)
            }
        }
        onConnected?()
    }

    func disconnect() {
        save { defaults in
            for key in [VaultConnector.Key.folder, VaultConnector.Key.tasks, VaultConnector.Key.daily, VaultConnector.Key.inbox] {
                defaults.removeObject(forKey: key)
            }
        }
    }

    /// A tasks file or folder, or the inbox file, inside the vault (kept relative to it).
    func choose(_ field: Field) {
        guard let folder else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = field == .tasks
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.message = Localization.string(field == .tasks ? "The file with your tasks, or a folder of them"
                                                            : "The file quick capture appends to")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let base = folder.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        let value = path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
        save { Self.set(value, field == .tasks ? VaultConnector.Key.tasks : VaultConnector.Key.inbox, in: $0) }
    }

    func clear(_ field: Field) {
        save { $0.removeObject(forKey: field == .tasks ? VaultConnector.Key.tasks : VaultConnector.Key.inbox) }
    }

    func setDaily(_ pattern: String) {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        save { Self.set(trimmed.isEmpty ? nil : trimmed, VaultConnector.Key.daily, in: $0) }
    }

    /// Writes the choice (not in previews), tells the live parts, reads it back.
    private func save(_ change: (UserDefaults) -> Void) {
        if persists {
            change(.standard)
            NotificationCenter.default.post(name: VaultLive.changed, object: nil)
        }
        refresh()
    }

    private static func set(_ value: String?, _ key: String, in defaults: UserDefaults) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

/// Onboarding's row: pick the folder; then what was found in it.
struct NotesRow: View {
    let state: AppState
    @State private var setup: VaultSetup

    init(state: AppState) {
        self.state = state
        _setup = State(initialValue: VaultSetup(persists: state.persists))
    }

    var body: some View {
        HStack(spacing: 12) {
            RowSymbol(name: "books.vertical", active: setup.isConnected)
            VStack(alignment: .leading, spacing: 2) {
                Text("Your notes").font(.system(size: 13, weight: .medium))
                status
                    .font(.system(size: 11.5))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if setup.isConnected {
                if !setup.isFromConfig {
                    Button("Change") { setup.chooseFolder() }
                        .buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 12))
                        .frame(minHeight: 28)
                }
            } else {
                Button("Choose folder…") { setup.chooseFolder() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
        }
        .animation(Onboarding.motion, value: setup.isConnected)
        .onAppear { setup.onConnected = { [state] in NotesTools.switchOnToday(state) } }
    }

    @ViewBuilder private var status: some View {
        if setup.isConnected {
            Label(setup.openTasks == 1 ? "\(setup.name) · 1 open task" as LocalizedStringKey : "\(setup.name) · \(setup.openTasks) open tasks",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(Theme.ok)
        } else {
            Text("An Obsidian vault or any Markdown folder: your tasks and today's note in the notch, and Tara reads along.")
                .foregroundStyle(.secondary)
        }
    }
}

/// Settings › Notes: the folder, and the files the notch uses in it.
struct NotesSettings: View {
    let state: AppState
    @State private var setup: VaultSetup
    @State private var daily = ""

    init(state: AppState) {
        self.state = state
        _setup = State(initialValue: VaultSetup(persists: state.persists))
    }

    var body: some View {
        Group { rows }
            .onAppear {
                daily = setup.layout.daily ?? ""
                setup.onConnected = { [state] in NotesTools.switchOnToday(state) }
            }
            .onChange(of: setup.layout.daily) { _, value in daily = value ?? "" }
    }

    @ViewBuilder private var rows: some View {
        LabeledContent("Folder") {
            HStack(spacing: 8) {
                Text(setup.folder.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? Localization.string("None"))
                    .foregroundStyle(setup.isConnected ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if setup.isFromConfig {
                    Text("config.toml").foregroundStyle(.secondary)
                } else {
                    Button(setup.isConnected ? "Change…" : "Choose…") { setup.chooseFolder() }
                    if setup.isConnected { Button("Remove") { setup.disconnect() } }
                }
            }
        }
        if setup.isConnected {
            fileRow("Tasks", setup.layout.tasks, field: .tasks,
                    detail: setup.openTasks == 1 ? "1 open task" : "\(setup.openTasks) open tasks")
            TextField(text: $daily, prompt: Text(verbatim: "Daily/YYYY-MM-DD.md")) {
                Text("Daily note")
                Text(setup.layout.daily == nil ? "Not set" as LocalizedStringKey
                     : setup.hasDailyNote ? "Today's note found" : "No note for today yet")
            }
            .disabled(setup.isFromConfig)
            .onSubmit { setup.setDaily(daily) }
            fileRow("Inbox", setup.layout.inbox, field: .inbox, detail: "Quick capture appends here")
        }
    }

    private func fileRow(_ title: LocalizedStringKey, _ path: String?, field: VaultSetup.Field, detail: LocalizedStringKey) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                Text(path ?? Localization.string("None"))
                    .foregroundStyle(path == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !setup.isFromConfig {
                    Button(path == nil ? "Choose…" : "Change…") { setup.choose(field) }
                    if path != nil && field == .inbox { Button("Remove") { setup.clear(field) } }
                }
            }
        } label: {
            Text(title)
            Text(detail)
        }
    }
}

enum NotesTools {
    /// Notes connected: Today has something to show, so it goes on (not in previews).
    @MainActor
    static func switchOnToday(_ state: AppState) {
        guard state.persists else { return }
        ToolSwitches.set(.module(.today), on: true, in: &state.settings)
    }
}
