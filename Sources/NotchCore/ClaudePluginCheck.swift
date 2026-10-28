import Foundation

// The approvals plugin stays registered: Claude Code skips a plugin without a word when its
// marketplace folder is gone, so the setup registers the marketplace from the app's own copy in
// the support folder, and at launch reads Claude Code's registry (never writes it) and repairs a
// stale registration through the claude command. Only for a plugin the user set up.

/// What the launch check does about the approvals plugin.
public enum ClaudePluginRepair: Equatable, Sendable {
    /// Nothing to do: all fine, the registry can't be read, or the user switched the plugin off.
    case fine
    /// Claude Code is fine; only the app's copy of the marketplace is out of date.
    case refreshCopy
    /// The marketplace points somewhere stale: remove it, add the app's copy, install the plugin.
    case reregister
    /// The marketplace is fine, the plugin is missing: install it.
    case install
}

/// Where Claude Code's registry says the "starnotch" marketplace comes from.
public enum MarketplaceSource: Equatable, Sendable {
    case github(String)
    case directory(String)
    case other
    /// Not registered.
    case absent
}

public enum ClaudePluginCheck {
    /// The "starnotch" entry of `known_marketplaces.json`; nil when the file isn't a JSON object.
    public static func marketplace(_ data: Data) -> MarketplaceSource? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let entry = root[SetupPaths.marketplaceName] as? [String: Any] else { return .absent }
        let source = entry["source"] as? [String: Any] ?? [:]
        if source["source"] as? String == "github", let repo = source["repo"] as? String { return .github(repo) }
        if let path = source["path"] as? String { return .directory(path) }
        return .other
    }

    /// The GitHub repository, or the app's copy while it is there.
    public static func isCurrent(_ source: MarketplaceSource, stableCopy: URL, exists: (String) -> Bool) -> Bool {
        switch source {
        case .github(let repo): repo.caseInsensitiveCompare(SetupPaths.marketplaceRepo) == .orderedSame
        case .directory(let path): samePath(path, stableCopy.path) && exists(path)
        case .other, .absent: false
        }
    }

    static func samePath(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).resolvingSymlinksInPath().standardizedFileURL.path
            == URL(fileURLWithPath: b).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Decides from Claude Code's registry: `known_marketplaces.json`, `installed_plugins.json`
    /// and `settings.json` (nil when a file isn't there). A file that can't be read leaves Claude
    /// Code alone; `enabledPlugins` false means the user switched the plugin off, and stays so.
    public static func decide(marketplaces: Data?, installed: Data?, settings: Data?, stableCopy: URL,
                              copyStale: Bool, exists: (String) -> Bool) -> ClaudePluginRepair {
        let keep: ClaudePluginRepair = copyStale ? .refreshCopy : .fine
        guard let marketplaces, let source = marketplace(marketplaces),
              let installed, let root = try? JSONSerialization.jsonObject(with: installed) as? [String: Any],
              let plugins = root["plugins"] as? [String: Any] else { return .fine }
        var enabledPlugins: [String: Any] = [:]
        if let settings, !settings.isEmpty {
            guard let object = try? JSONSerialization.jsonObject(with: settings) as? [String: Any] else { return .fine }
            enabledPlugins = object["enabledPlugins"] as? [String: Any] ?? [:]
        }
        let enabled = enabledPlugins[SetupPaths.pluginID]
        if (enabled as? Bool) == false { return keep }
        guard isCurrent(source, stableCopy: stableCopy, exists: exists) else { return .reregister }
        let isInstalled = (plugins[SetupPaths.pluginID] as? [Any])?.isEmpty == false
        return isInstalled && enabled != nil ? keep : .install
    }
}

extension SetupPaths {
    /// The marketplace folder inside the app.
    public var claudePluginBundle: URL? { integrations?.appending(path: "claude-code") }
    /// The app's copy of it, which the marketplace is registered from: moving or updating the app
    /// doesn't break it.
    public var claudePluginCopy: URL { support.appending(path: "integrations/claude-code") }
    public var knownMarketplaces: URL { home.appending(path: ".claude/plugins/known_marketplaces.json") }
    public var installedPlugins: URL { home.appending(path: ".claude/plugins/installed_plugins.json") }
}

extension SetupActions {
    /// Every file below `folder` by its relative path; nil when the folder isn't there.
    static func contents(_ folder: URL) -> [String: Data]? {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue,
              let names = FileManager.default.enumerator(atPath: folder.path) else { return nil }
        var files: [String: Data] = [:]
        for case let name as String in names {
            if let data = try? Data(contentsOf: folder.appending(path: name)) { files[name] = data }
        }
        return files
    }

    /// The copy is there and differs from the folder inside the app.
    public static func isClaudePluginCopyStale(_ paths: SetupPaths) -> Bool {
        guard let bundled = paths.claudePluginBundle.flatMap(contents), let copy = contents(paths.claudePluginCopy) else { return false }
        return bundled != copy
    }

    /// Puts the app's marketplace folder into the support folder (unless the copy is already the same).
    @discardableResult
    static func placeClaudePluginCopy(_ paths: SetupPaths) throws -> URL {
        let fm = FileManager.default
        guard let bundled = paths.claudePluginBundle,
              fm.fileExists(atPath: bundled.appending(path: ".claude-plugin/marketplace.json").path) else {
            throw SetupError.missing("The plugin inside the app")
        }
        let copy = paths.claudePluginCopy
        if let current = contents(copy), current == contents(bundled) { return copy }
        try fm.createDirectory(at: paths.support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fresh = copy.deletingLastPathComponent().appending(path: "claude-code.new")
        try? fm.removeItem(at: fresh)
        try fm.copyItem(at: bundled, to: fresh)
        try? fm.removeItem(at: copy)
        try fm.moveItem(at: fresh, to: copy)
        return copy
    }

    /// The first line of a command's output, for the setup page.
    static func firstLine(_ output: String) -> String {
        output.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    /// At launch, for a plugin the user set up: reads Claude Code's registry and repairs what
    /// `ClaudePluginCheck.decide` finds. Throws a short reason; the caller runs it once.
    @discardableResult
    public static func checkClaudePlugin(_ paths: SetupPaths, ledger: SetupLedger, run: SetupRunner = processRunner) throws -> ClaudePluginRepair {
        guard ledger.entry(.claudePlugin) != nil else { return .fine }
        let stale = isClaudePluginCopyStale(paths)
        let repair = ClaudePluginCheck.decide(
            marketplaces: try? Data(contentsOf: paths.knownMarketplaces),
            installed: try? Data(contentsOf: paths.installedPlugins),
            settings: try? Data(contentsOf: paths.claudeSettings),
            stableCopy: paths.claudePluginCopy, copyStale: stale,
            exists: { FileManager.default.fileExists(atPath: $0) })
        let env = ["HOME": paths.home.path]
        func install(_ claude: String) throws {
            let installed = run(claude, ["plugin", "install", SetupPaths.pluginID, "--scope", "user"], env)
            guard installed.status == 0 else { throw SetupError.failed("Couldn't install the plugin: \(firstLine(installed.output))") }
        }
        switch repair {
        case .fine: break
        case .refreshCopy: try placeClaudePluginCopy(paths)
        case .reregister:
            guard let claude = paths.claudeBinary else { throw SetupError.missing("The claude command") }
            let copy = try placeClaudePluginCopy(paths)
            _ = run(claude, ["plugin", "marketplace", "remove", SetupPaths.marketplaceName], env)
            let added = run(claude, ["plugin", "marketplace", "add", copy.path], env)
            guard added.status == 0 else { throw SetupError.failed("Couldn't add the marketplace: \(firstLine(added.output))") }
            try install(claude)
        case .install:
            guard let claude = paths.claudeBinary else { throw SetupError.missing("The claude command") }
            if stale { try placeClaudePluginCopy(paths) }
            try install(claude)
        }
        return repair
    }
}
