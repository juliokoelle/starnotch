import Foundation

/// The shelf's files across launches (Settings › Tools): a bookmark per file, which follows a
/// file that was renamed or moved, and its path as a fallback. Nothing is copied; a file that is
/// gone (or in the Trash) drops out quietly.
public struct ShelfMemory: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public var path: String
        public var bookmark: Data?

        public init(path: String, bookmark: Data?) {
            self.path = path
            self.bookmark = bookmark
        }
    }

    public var items: [Item]

    public init(items: [Item]) {
        self.items = items
    }

    /// The shelf as it is now.
    public init(_ urls: [URL]) {
        items = urls.map { Item(path: $0.path, bookmark: try? $0.bookmarkData()) }
    }

    /// The files still there, in the shelf's order, each once. Resolving never mounts a volume or
    /// asks anything, so it may run off the main thread at launch.
    public func restore() -> [URL] {
        var seen = Set<String>()
        return items.compactMap { item in
            guard let url = Self.resolve(item), seen.insert(url.path).inserted else { return nil }
            return url
        }
    }

    private static func resolve(_ item: Item) -> URL? {
        var found: URL?
        if let bookmark = item.bookmark {
            var stale = false
            found = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                             relativeTo: nil, bookmarkDataIsStale: &stale)
        }
        let url = found ?? URL(fileURLWithPath: item.path)
        guard !isInTrash(url.path), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url.standardizedFileURL
    }

    /// A bookmark follows a file into the Trash; for the shelf it's gone.
    static func isInTrash(_ path: String) -> Bool {
        path.contains("/.Trash/") || path.contains("/.Trashes/")
    }
}

/// Names for the files the shelf's actions make. They never take an existing file's name, so
/// nothing is replaced.
public enum ShelfNames {
    /// What Finder's Compress calls a zip of one item: `Report.pdf.zip`, `Photos.zip`.
    public static func zip(of name: String) -> String { name + ".zip" }

    /// `name` if `taken` says it's free, else `Report 2.pdf`, `Report 3.pdf` … (the number before
    /// the extension, as Finder's Keep Both does).
    public static func free(_ name: String, taken: (String) -> Bool) -> String {
        guard taken(name) else { return name }
        let dot = name.lastIndex(of: ".").flatMap { $0 > name.startIndex ? $0 : nil }
        let base = dot.map { String(name[..<$0]) } ?? name
        let ext = dot.map { String(name[$0...]) } ?? ""
        var number = 2
        while taken("\(base) \(number)\(ext)") { number += 1 }
        return "\(base) \(number)\(ext)"
    }

    /// A folder can't be copied into itself or into a folder inside it.
    public static func isInside(_ folder: String, of item: String) -> Bool {
        let item = item.hasSuffix("/") ? String(item.dropLast()) : item
        return folder == item || folder.hasPrefix(item + "/")
    }
}
