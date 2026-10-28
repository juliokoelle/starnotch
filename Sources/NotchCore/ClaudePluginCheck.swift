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
        if let url = source["url"] as? String, namesRepo(url) { return .github(SetupPaths.marketplaceRepo) }
        if let path = source["path"] as? String { return .directory(path) }
        return .other
    }

    /// A git or URL source that names the GitHub repository.
    static func namesRepo(_ url: String) -> Bool {
        var url = url.lowercased()
        while url.hasSuffix("/") { url.removeLast() }
        if url.hasSuffix(".git") { url.removeLast(4) }
        let repo = SetupPaths.marketplaceRepo.lowercased()
        return url.hasSuffix("github.com/\(repo)") || url.hasSuffix("github.com:\(repo)")
    }

    /// The GitHub repository, the app's copy while it is there, or another folder that holds the
    /// marketplace outside an app (another build's copy, a checkout): a folder inside an app goes
    /// when the app is moved, updated or deleted.
    public static func isCurrent(_ source: MarketplaceSource, stableCopy: URL, exists: (String) -> Bool) -> Bool {
        switch source {
        case .github(let repo): repo.caseInsensitiveCompare(SetupPaths.marketplaceRepo) == .orderedSame
        case .directory(let path) where samePath(path, stableCopy.path): exists(path)
        case .directory(let path): !insideApp(path) && exists(URL(fileURLWithPath: path).appending(path: ".claude-plugin/marketplace.json").path)
        case .other, .absent: false
        }
    }

    /// Inside an app bundle, or a translocated copy of one.
    static func insideApp(_ path: String) -> Bool {
        let path = path.lowercased()
        return path.contains(".app/") || path.contains("/apptranslocation/")
    }

    static func samePath(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).resolvingSymlinksInPath().standardizedFileURL.path
            == URL(fileURLWithPath: b).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Decides from Claude Code's registry: `known_marketplaces.json`, `installed_plugins.json`
    /// and `settings.json` (nil when a file isn't there). A file that can't be read leaves Claude
    /// Code alone; `enabledPlugins` false means the user switched the plugin off, and stays so; a
    /// marketplace Claude Code doesn't know (the user removed it) isn't skipped, and stays away.
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
        if (enabled as? Bool) == false || source == .absent { return keep }
        guard isCurrent(source, stableCopy: stableCopy, exists: exists) else { return .reregister }
        // Installed in any scope and any format; an empty list is none.
        let isInstalled = plugins[SetupPaths.pluginID].map { ($0 as? [Any])?.isEmpty != true } ?? false
        return isInstalled ? keep : .install
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
        // Swapped in one step from a folder of its own: a session starting meanwhile still finds it.
        let fresh = copy.deletingLastPathComponent().appending(path: "claude-code.\(UUID().uuidString)")
        defer { try? fm.removeItem(at: fresh) }
        try fm.copyItem(at: bundled, to: fresh)
        if fm.fileExists(atPath: copy.path) {
            _ = try fm.replaceItemAt(copy, withItemAt: fresh)
        } else {
            try fm.moveItem(at: fresh, to: copy)
        }
        return copy
    }

    /// The first line of a command's output, for the setup page.
    static func firstLine(_ output: String) -> String {
        output.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    /// Registers the marketplace again from the app's copy. When that fails, `previous` goes back
    /// in while it is still there, so a working registration isn't lost.
    @discardableResult
    static func registerClaudePluginCopy(_ paths: SetupPaths, claude: String, previous: MarketplaceSource,
                                         run: SetupRunner, env: [String: String]) throws -> URL {
        let copy = try placeClaudePluginCopy(paths)
        _ = run(claude, ["plugin", "marketplace", "remove", SetupPaths.marketplaceName], env)
        let added = run(claude, ["plugin", "marketplace", "add", copy.path], env)
        guard added.status == 0 else {
            let back: String? = switch previous {
            case .github(let repo): repo
            case .directory(let path) where FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).appending(path: ".claude-plugin/marketplace.json").path): path
            default: nil
            }
            if let back { _ = run(claude, ["plugin", "marketplace", "add", back], env) }
            throw SetupError.failed("Couldn't add the marketplace: \(firstLine(added.output))")
        }
        return copy
    }

    /// At launch, for a plugin the user set up: reads Claude Code's registry and repairs what
    /// `ClaudePluginCheck.decide` finds. Throws a short reason; the caller runs it once.
    @discardableResult
    public static func checkClaudePlugin(_ paths: SetupPaths, ledger: SetupLedger, run: SetupRunner = processRunner) throws -> ClaudePluginRepair {
        guard ledger.entry(.claudePlugin) != nil else { return .fine }
        let stale = isClaudePluginCopyStale(paths)
        let marketplaces = try? Data(contentsOf: paths.knownMarketplaces)
        let repair = ClaudePluginCheck.decide(
            marketplaces: marketplaces,
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
            let previous = marketplaces.flatMap(ClaudePluginCheck.marketplace) ?? .absent
            try registerClaudePluginCopy(paths, claude: claude, previous: previous, run: run, env: env)
            try install(claude)
        case .install:
            guard let claude = paths.claudeBinary else { throw SetupError.missing("The claude command") }
            if stale { try placeClaudePluginCopy(paths) }
            try install(claude)
        }
        return repair
    }
}
