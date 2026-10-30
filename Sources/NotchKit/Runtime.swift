import Foundation
import NotchCore

/// Launch-time configuration: `config.toml` and the linked connectors. Set once in
/// `AppDelegate.applicationDidFinishLaunching` before any module reads it, never changed after.
enum Runtime {
    nonisolated(unsafe) private(set) static var config = NotchConfig()
    nonisolated(unsafe) private(set) static var connectors: [any NotchConnector] = []

    /// Reads `config.toml` (writing a commented template the first time) over the build's own
    /// defaults, then starts the enabled connectors among `types`. All linked connectors run
    /// unless `[connectors] enabled` lists ids.
    static func start(connectorTypes types: [any NotchConnector.Type], buildConfig: String = "",
                      configURL: URL = NotchConfig.defaultURL) {
        ConfigTemplate.writeIfMissing(at: configURL)
        var config = (try? NotchConfig.parse(buildConfig)) ?? NotchConfig()
        let (user, error) = NotchConfig.load(from: configURL)
        if let error { Log.app.error("\(error.description, privacy: .public)") }
        config.merge(user)
        // The notes vault's run log feeds the loops unless [connectors.runlog] names its own.
        if config.connector(RunLogConnector.id).string("file") == nil,
           let loops = VaultConnector(config: config.connector(VaultConnector.id)).loopsFile {
            config.sections["connectors.\(RunLogConnector.id)", default: [:]]["file"] = .string(loops.path)
        }
        self.config = config
        let enabled = config["connectors"].strings("enabled")
        connectors = types
            .filter { enabled?.contains($0.id) ?? true }
            .map { $0.init(config: config.connector($0.id)) }
        Log.app.info("Connectors: \(connectors.map { type(of: $0).id }.joined(separator: ", "), privacy: .public)")
    }

    /// The first connector offering `type` that is set up.
    static func first<T>(_ type: T.Type) -> T? { connectors.lazy.filter(\.isConfigured).compactMap { $0 as? T }.first }

    /// The notes connector, set up or not (Settings and onboarding pick its folder).
    static var vault: VaultConnector? { connectors.lazy.compactMap { $0 as? VaultConnector }.first }

    static var today: (any TodayProvider)? { first((any TodayProvider).self) }
    static var jobs: (any JobsProvider)? { first((any JobsProvider).self) }
    static var people: (any PeopleProvider)? { first((any PeopleProvider).self) }
    static var inbox: (any InboxSink)? { first((any InboxSink).self) }

    // MARK: Settings from config.toml

    static var claudeDir: URL {
        config["agents"].path("claude_dir") ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
    }

    /// launchd jobs whose label starts with this show in the agents panel; empty shows none.
    static var launchdPrefix: String { config["agents"].string("launchd_prefix", default: "") }

    /// The project whose character stands in where no session is involved (music, dictation).
    static var homeProject: String { config["characters"].string("home_project", default: "") }

    /// The lead character (`[characters] main`), else the first of the first pack.
    static var mainCharacter: String? { config["characters"].string("main") }

    /// Pack ids to load (`[characters] packs`); all packs found when unset.
    static var characterPacks: [String]? { config["characters"].strings("packs").flatMap { $0.isEmpty ? nil : $0 } }

    /// The character for every project without a pick or default (`[characters] fallback`): unset,
    /// the lead character (projects differ by colour); empty, each project gets its own.
    static var fallbackCharacter: String? {
        guard let value = config["characters"].string("fallback") else { return AvatarLibrary.shared.characters.first?.id }
        return value.isEmpty ? nil : value
    }

    /// Project → character id defaults, e.g. `projects = ["notes:pebble"]`.
    static var projectCharacters: [String: String] {
        var result: [String: String] = [:]
        for pair in config["characters"].strings("projects") ?? [] {
            let parts = pair.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty { result[parts[0]] = parts[1] }
        }
        return result
    }

    /// Room beside the hardware notch the island may take in the menu bar, per side, including
    /// its curved corner (`[island] menu_bar_room`). Menu bar extras start right after it: macOS
    /// doesn't let other apps read where, so this is a measured, conservative default.
    static var menuBarRoom: CGFloat { CGFloat(config["island"].int("menu_bar_room", default: 30)) }

    /// Port of the local status API.
    static var apiPort: UInt16 { UInt16(clamping: config["api"].int("port", default: 47789)) }

    /// Quick capture without an inbox connector appends here as Markdown tasks: the file config.toml
    /// names (`""` keeps only the local queue), else the notes vault's inbox, else `Inbox.md` in
    /// the visible Starnotch folder in Documents.
    static var captureMarkdownFile: URL? {
        let section = config["capture"]
        guard let raw = section.string("markdown_file") else {
            return vault?.inboxFile ?? MarkdownInbox.defaultFile
        }
        return raw.trimmingCharacters(in: .whitespaces).isEmpty ? nil : section.path("markdown_file")
    }

    /// The meeting agent's folder, where `uv run` starts its programs: `[meeting] agent_dir`, else
    /// the copy of the agent inside the app, else a checkout in ~/starnotch-jamie.
    static var meetingAgentDir: URL {
        config["meeting"].path("agent_dir")
            ?? MeetingAgentSetup.ensureInstalled()
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "starnotch-jamie/agent")
    }

    /// `en`, `de` or `system`.
    static var language: String { config["general"].string("language", default: "system") }
}

/// The commented config written on first launch, so the file documents itself.
enum ConfigTemplate {
    static let text = """
    # \(Brand.name) configuration. Read at launch; restart the app after changes.
    # Every key is optional; the commented values are the defaults.

    [general]
    # Interface language: "system", "en" or "de".
    # language = "system"

    [agents]
    # Where Claude Code keeps its sessions and transcripts.
    # claude_dir = "~/.claude"
    # Show launchd jobs whose label starts with this prefix in the agents panel ("" = none).
    # launchd_prefix = ""

    [characters]
    # The project whose character appears outside sessions (music, dictation, capture).
    # home_project = ""
    # Character packs to use, by id (".notchpack" folders in the app or in Characters/ here);
    # empty = all of them.
    # packs = []
    # The lead character (id from a pack); empty = the first character of the first pack.
    # main = ""
    # The character for every project without a pick; unset = the lead character (projects differ
    # by colour), "" = a different character per project.
    # fallback = "astra"
    # Fixed characters per project, as "project:character".
    # projects = []

    [island]
    # Points beside the notch the island may cover in the menu bar (peek, sneak, compact), per
    # side. Raise it if your menu bar has room; lower it if the island covers an icon.
    # menu_bar_room = 30

    [api]
    # Local status API on 127.0.0.1 (switch it on in Settings).
    # port = 47789

    [capture]
    # Without an inbox connector, quick capture appends Markdown tasks here (default: the vault's inbox, else ~/Documents/Starnotch/Inbox.md;
    # "" = only the local queue). The Inbox button in quick capture opens it.
    # markdown_file = ""

    [meeting]
    # The meeting agent's folder (agent/ of the Starnotch repo); its programs run there with uv.
    # agent_dir = "~/starnotch-jamie/agent"

    [connectors]
    # Connector ids to run; leave out to run every connector linked into this build.
    # enabled = []

    # Your notes (an Obsidian vault or any Markdown folder); Settings › Notes picks the same.
    # Paths are relative to the folder.
    # [connectors.vault]
    # folder = "~/notes"
    # tasks = "Tasks.md"              # a file or a folder with "- [ ]" tasks
    # daily = "Daily/YYYY-MM-DD.md"   # the daily note
    # inbox = "Inbox.md"              # quick capture appends here
    # loops = "loops/RUNLOG.md"       # the loops' run log
    """

    static func writeIfMissing(at url: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else { return }
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        fm.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
    }
}
