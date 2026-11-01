import Foundation

/// One tile of the launcher in the Tools tab: an Apple Shortcut, run by its name, or an app.
public struct LauncherItem: Codable, Equatable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case shortcut, app }

    public var kind: Kind
    /// The shortcut's name (how `shortcuts run` finds it), or the app's.
    public var name: String
    /// Apps: the bundle and where it was last found.
    public var app: SlotApp?

    public init(kind: Kind, name: String, app: SlotApp? = nil) {
        self.kind = kind
        self.name = name
        self.app = app
    }

    public static func shortcut(_ name: String) -> LauncherItem { LauncherItem(kind: .shortcut, name: name) }
    public static func app(_ app: SlotApp) -> LauncherItem { LauncherItem(kind: .app, name: app.name, app: app) }

    /// Stable across launches: a shortcut by its name, an app by its bundle.
    public var id: String { kind == .app ? "app:\(app?.bundleID ?? name)" : "shortcut:\(name)" }
}

/// The launcher's list as picked in Settings: each item once, in the user's order.
public enum Launcher {
    /// `shortcuts list` prints one name per line: blank lines and repeats are dropped, the order kept.
    public static func shortcutNames(from output: String) -> [String] {
        var seen = Set<String>()
        return output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The shortcuts not picked yet whose name contains the query (case and accents ignored).
    public static func shortcuts(_ names: [String], matching query: String, besides items: [LauncherItem]) -> [String] {
        let picked = Set(items.filter { $0.kind == .shortcut }.map(\.name))
        let needle = query.trimmingCharacters(in: .whitespaces)
        return names.filter { name in
            !picked.contains(name) && (needle.isEmpty || name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil)
        }
    }

    /// At the end, unless it's in the list already.
    public static func add(_ item: LauncherItem, to items: inout [LauncherItem]) {
        guard !items.contains(where: { $0.id == item.id }) else { return }
        items.append(item)
    }

    /// One place up (-1) or down (+1); at either end nothing changes.
    public static func move(_ id: String, by step: Int, in items: inout [LauncherItem]) {
        guard let index = items.firstIndex(where: { $0.id == id }), items.indices.contains(index + step) else { return }
        items.swapAt(index, index + step)
    }

    public static func remove(_ id: String, from items: inout [LauncherItem]) {
        items.removeAll { $0.id == id }
    }
}
