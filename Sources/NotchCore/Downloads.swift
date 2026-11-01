import Foundation

/// A file in the watched folder as one listing sees it: its name, file number (which a rename
/// keeps), size and whether it is a plain file. Nothing of its contents.
public struct DownloadEntry: Equatable, Sendable {
    public var name: String
    public var inode: UInt64
    public var size: Int64
    /// Not a folder, a link or a bundle.
    public var isFile: Bool

    public init(name: String, inode: UInt64, size: Int64, isFile: Bool = true) {
        self.name = name
        self.inode = inode
        self.size = size
        self.isFile = isFile
    }
}

/// Which downloads finished, from one listing of the Downloads folder after the next. A
/// browser's temporary file (.crdownload, .download, .part, .opdownload) that becomes the final
/// file, or goes away while the final file is there, finished it; any other new file finishes
/// once its size stays the same from one listing to the next. Hidden files, folders and the
/// temporary files themselves never count, nor does a file renamed inside the folder.
public struct DownloadWatch: Sendable {
    public static let temporaryExtensions: Set<String> = ["crdownload", "download", "part", "opdownload"]

    /// The last listing by name; nil before the first one.
    private var entries: [String: DownloadEntry]?
    /// New files whose size may still grow, with their size at the last listing.
    private var settling: [String: Int64] = [:]
    /// Files next to their own temporary file (Firefox's empty placeholder, Safari's file before
    /// its bundle goes): they finish when it is gone.
    private var waiting: Set<String> = []

    public init() {}

    /// A new file's size is still settling: list again in a moment. Files waiting for their
    /// temporary file don't count; its going is a change to the folder.
    public var isSettling: Bool { !settling.isEmpty }

    public static func isTemporary(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        return temporaryExtensions.contains(name[name.index(after: dot)...].lowercased())
    }

    /// "report.pdf.crdownload" → "report.pdf".
    public static func finalName(of temporary: String) -> String? {
        guard isTemporary(temporary), let dot = temporary.lastIndex(of: ".") else { return nil }
        return String(temporary[..<dot])
    }

    /// The names of the downloads that finished since the last listing. The first listing is
    /// what was there already and finishes nothing.
    public mutating func update(_ listing: [DownloadEntry]) -> [String] {
        var current: [String: DownloadEntry] = [:]
        for entry in listing { current[entry.name] = entry }
        defer {
            entries = current
            settling = settling.filter { current[$0.key] != nil }
            waiting = waiting.filter { current[$0] != nil }
        }
        guard let previous = entries else { return [] }
        var byInode: [UInt64: DownloadEntry] = [:]
        for entry in previous.values { byInode[entry.inode] = entry }
        // Safari moves the finished file out of its .download bundle and removes the bundle.
        let goneTemporary = Set(previous.keys.filter { current[$0] == nil }.compactMap(Self.finalName))
        var finished: [String] = []
        for entry in listing.sorted(by: { $0.name < $1.name })
        where entry.isFile && !entry.name.hasPrefix(".") && !Self.isTemporary(entry.name) {
            let name = entry.name
            let hasTemporary = Self.temporaryExtensions.contains { current["\(name).\($0)"] != nil }
            if let old = previous[name], old.inode == entry.inode {
                if waiting.contains(name) {
                    guard !hasTemporary else { continue }
                    waiting.remove(name)
                    if entry.size > 0 { finished.append(name) }
                } else if let last = settling[name] {
                    if entry.size != last {
                        settling[name] = entry.size
                    } else {
                        settling[name] = nil
                        if entry.size > 0 { finished.append(name) }
                    }
                }
                continue
            }
            // A new name, or a new file under an old one.
            settling[name] = nil
            waiting.remove(name)
            if let before = byInode[entry.inode] {
                // Chrome and Opera rename their temporary file; Firefox moves its .part over the placeholder.
                if Self.isTemporary(before.name) { finished.append(name); continue }
                // Renamed in the folder. From a hidden name it may still be written: it settles first.
                if !before.name.hasPrefix(".") { continue }
            } else if goneTemporary.contains(name), entry.size > 0 {
                finished.append(name)
                continue
            }
            if hasTemporary {
                waiting.insert(name)
            } else {
                settling[name] = entry.size
            }
        }
        return finished
    }
}
