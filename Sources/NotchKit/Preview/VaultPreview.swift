import AppKit
import NotchCore
import SwiftUI

/// A made-up notes vault for previews and screenshots (`--preview today:vault`,
/// `--preview onboarding:2:notes`, `--preview notes-settings[-edit]`): written fresh into a
/// temporary folder on each launch, so ticking a task off there touches nothing of the user's.
enum VaultSamples {
    static var folder: URL { FileManager.default.temporaryDirectory.appending(path: "starnotch-sample/Notes") }

    /// The sample vault from config.toml, or with `picked` as picked in Settings (so Settings
    /// shows its buttons), or with `empty` a connector with no folder (nothing set up yet).
    static func connector(empty: Bool = false, picked: Bool = false) -> VaultConnector {
        let defaults = UserDefaults(suiteName: Brand.identifier + ".preview-vault") ?? .standard
        for key in [VaultConnector.Key.folder, VaultConnector.Key.tasks, VaultConnector.Key.daily, VaultConnector.Key.inbox] {
            defaults.removeObject(forKey: key)
        }
        guard !empty else { return VaultConnector(config: ConfigSection(), defaults: defaults, snapshotURL: nil) }
        write(now: Date())
        if picked {
            defaults.set(folder.path, forKey: VaultConnector.Key.folder)
            defaults.set("Tasks.md", forKey: VaultConnector.Key.tasks)
            defaults.set("Daily/YYYY-MM-DD.md", forKey: VaultConnector.Key.daily)
            defaults.set("Inbox.md", forKey: VaultConnector.Key.inbox)
            return VaultConnector(config: ConfigSection(), defaults: defaults, snapshotURL: nil)
        }
        let config = ConfigSection(name: "connectors.vault", values: [
            "folder": .string(folder.path), "tasks": .string("Tasks.md"),
            "daily": .string("Daily/YYYY-MM-DD.md"), "inbox": .string("Inbox.md"),
        ])
        return VaultConnector(config: config, defaults: defaults, snapshotURL: nil)
    }

    private static func write(now: Date) {
        let day = { (offset: Double) in RunLog.day(now.addingTimeInterval(offset * 86_400)) }
        let files: [String: String] = [
            "Tasks.md": """
            # Tasks

            ## This week
            - [ ] Renew the domain 📅 \(day(-1))
            - [ ] Send the review notes to Ada 📅 \(day(0)) #work
            - [ ] **Draft the launch post.** Under 300 words, one picture [due:: \(day(0))]
              - Ask Grace for the quote
            - [ ] Book flights for the offsite 📅 \(day(2)) #travel
            - [ ] Prepare the board update [due:: \(day(4))]
            - [x] Order the new monitor 📅 \(day(-1))

            ## Someday
            - [ ] Read The Mythical Man-Month
            - [ ] Clean up old branches

            """,
            "Daily/\(day(0)).md": """
            ---
            date: \(day(0))
            ---
            # \(day(0))

            ## Plan
            - Design review at 12:30

            ## Notes

            ## Log

            """,
            "Inbox.md": """
            # Inbox

            - [ ] Call the bank about the card
            - [ ] Idea: a weekly review template

            """,
        ]
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        try? fm.createDirectory(at: folder.appending(path: ".obsidian"), withIntermediateDirectories: true)
        for (path, text) in files {
            let url = folder.appending(path: path)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: url)
        }
    }
}

/// `--preview notes-settings`: Settings › Notes on its own, on the sample vault from config.toml;
/// `notes-settings-edit`: as picked in Settings, with its buttons.
@MainActor
enum NotesSettingsPreview {
    private static var window: NSWindow?

    static func show(state: AppState) {
        let form = Form {
            Section {
                NotesSettings(state: state)
            } header: {
                Text("Notes")
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 300)
        let window = NSWindow(contentViewController: NSHostingController(rootView: form))
        window.title = Localization.string("Settings")
        window.center()
        // Above other apps, for the screenshot.
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}
