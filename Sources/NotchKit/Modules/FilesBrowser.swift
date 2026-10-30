import AppKit
import NotchCore
import Observation
import SwiftUI

/// A small Finder in the Tools tab: places on the left (recent files, Desktop, Downloads,
/// Documents, iCloud Drive, home), the open folder on the right, sorted by date or name. A click
/// opens a folder in place, like the places; a file is picked on one click and opens in its app
/// on two; files drag out into other apps, and files dropped on a folder (from the shelf, Finder or
/// another app) are copied into it. Files never moves or deletes anything: in a panel this small a
/// slip is too easy. Folders are read off the
/// main thread and only while the tab shows, so macOS asks for Desktop, Documents and Downloads
/// only when the user opens one of them here.
@MainActor
@Observable
final class FilesBrowser {
    struct Entry: Identifiable, Equatable {
        var url: URL
        var isFolder: Bool
        var modified: Date
        var size: Int?
        var id: URL { url }
        var name: String { url.lastPathComponent }
    }

    enum Place: String, CaseIterable, Identifiable {
        case recent = "Recent", desktop = "Desktop", downloads = "Downloads", documents = "Documents"
        case iCloud = "iCloud Drive", home = "Home"
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .recent: "clock"
            case .desktop: "menubar.dock.rectangle"
            case .downloads: "arrow.down.circle"
            case .documents: "doc"
            case .iCloud: "icloud"
            case .home: "house"
            }
        }

        var url: URL? {
            let home = FileManager.default.homeDirectoryForCurrentUser
            switch self {
            case .recent: return nil
            case .desktop: return home.appending(path: "Desktop", directoryHint: .isDirectory)
            case .downloads: return home.appending(path: "Downloads", directoryHint: .isDirectory)
            case .documents: return home.appending(path: "Documents", directoryHint: .isDirectory)
            case .iCloud: return home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)
            case .home: return home
            }
        }
    }

    enum Sort: String { case date, name }

    private(set) var place = Place.recent
    /// Newest first or A to Z; folders always before files. Remembered.
    var sort = Sort(rawValue: UserDefaults.standard.string(forKey: "files.sort") ?? "") ?? .date {
        didSet { UserDefaults.standard.set(sort.rawValue, forKey: "files.sort") }
    }
    /// Folders opened inside the place, the last one shown.
    private(set) var path: [URL] = []
    private(set) var entries: [Entry] = []
    /// The folder the shown entries belong to; the list slides when it changes, by `direction`.
    private(set) var shownKey = ""
    private(set) var direction: CGFloat = 1
    /// The entries in the chosen order.
    var shown: [Entry] { Self.sorted(entries, by: sort) }
    private(set) var loading = false
    var selected: URL?
    @ObservationIgnored private var generation = 0

    /// A folder lists at most this many entries, newest first (a huge Downloads stays quick).
    nonisolated static let limit = 300
    /// Recent: files changed in the last two weeks in Desktop, Downloads and Documents.
    nonisolated static let recentDays = 14

    var folder: URL? { path.last ?? place.url }
    var title: String { path.last?.lastPathComponent ?? Localization.string(place.rawValue) }

    func show(_ place: Place) {
        self.place = place
        path = []
        direction = 1
        reload()
    }

    func open(_ entry: Entry) {
        if entry.isFolder {
            guard path.last != entry.url else { return }  // the second click of a double click
            Haptics.open()
            direction = 1
            path.append(entry.url)
            reload()
        } else {
            Haptics.confirm()
            NSWorkspace.shared.open(entry.url)
        }
    }

    func back() {
        guard !path.isEmpty else { return }
        Haptics.tick()
        direction = -1
        path.removeLast()
        reload()
    }

    func select(_ entry: Entry) {
        guard selected != entry.url else { return }
        Haptics.tick()
        withAnimation(.spring(response: 0.22, dampingFraction: 0.75)) { selected = entry.url }
    }

    func reveal(_ url: URL? = nil) {
        if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        else if let folder { NSWorkspace.shared.open(folder) }
    }

    func copyPath(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    func reload() {
        generation += 1
        let started = generation
        let place = place, folder = folder
        loading = true
        Task.detached(priority: .userInitiated) {
            let listed = place == .recent && folder == nil ? Self.recent() : folder.map { Self.list($0) } ?? []
            await MainActor.run {
                guard self.generation == started else { return }
                withAnimation(Theme.snappy) {
                    self.entries = listed
                    self.shownKey = folder?.path ?? place.rawValue
                }
                self.loading = false
            }
        }
    }

    nonisolated static func sorted(_ entries: [Entry], by sort: Sort) -> [Entry] {
        let order: (Entry, Entry) -> Bool = sort == .name
            ? { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            : { $0.modified > $1.modified }
        return entries.filter(\.isFolder).sorted(by: order) + entries.filter { !$0.isFolder }.sorted(by: order)
    }

    // MARK: Dropping files into a folder

    /// Copies files into `folder` (never moves them); a name that's taken gets " 2", a folder into
    /// its own inside is left alone. Returns what went where.
    nonisolated static func drop(_ urls: [URL], into folder: URL) -> [(from: URL, to: URL)] {
        let fm = FileManager.default
        var done: [(URL, URL)] = []
        let target = folder.standardizedFileURL
        for url in urls.map(\.standardizedFileURL) {
            guard url != target, !target.path.hasPrefix(url.path + "/"), fm.fileExists(atPath: url.path) else { continue }
            let destination = free(target.appending(path: url.lastPathComponent))
            do {
                try fm.copyItem(at: url, to: destination)
                done.append((url, destination))
            } catch {
                continue
            }
        }
        return done
    }

    /// "Report.pdf", else "Report 2.pdf", "Report 3.pdf" …
    nonisolated static func free(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        let folder = url.deletingLastPathComponent()
        for n in 2... {
            let candidate = folder.appending(path: ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }

    /// Files dropped on a row or the list: copied off the main thread, then the folder is read again.
    /// A row of this list dropped back on it (a drag that slipped) does nothing.
    func receive(_ providers: [NSItemProvider], into folder: URL, tools: ToolsModule) -> Bool {
        let own = Set(entries.map(\.url.standardizedFileURL))
        let urls = URLBox()
        let group = DispatchGroup()
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { urls.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .global(qos: .userInitiated)) {
            let moved = Self.drop(urls.all.filter { !own.contains($0.standardizedFileURL) }, into: folder)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard !moved.isEmpty else { return }
                    Haptics.confirm()
                    tools.flash(String(format: Localization.string("Copied to %@"), folder.lastPathComponent))
                    self.reload()
                }
            }
        }
        return true
    }

    private final class URLBox: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        var all: [URL] { lock.withLock { urls } }
        func append(_ url: URL) { lock.withLock { urls.append(url) } }
    }

    // MARK: Reading folders

    nonisolated private static let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .contentModificationDateKey, .fileSizeKey]

    /// Folders first, then files, each newest first; hidden files and packages' insides stay out.
    nonisolated static func list(_ folder: URL) -> [Entry] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                 options: [.skipsHiddenFiles])) ?? []
        let entries = urls.compactMap(entry)
        let folders = entries.filter(\.isFolder).sorted { $0.modified > $1.modified }
        let files = entries.filter { !$0.isFolder }.sorted { $0.modified > $1.modified }
        return Array((folders + files).prefix(limit))
    }

    nonisolated static func recent(now: Date = Date()) -> [Entry] {
        let since = now.addingTimeInterval(-Double(recentDays) * 86_400)
        let files = [Place.desktop, .downloads, .documents].compactMap(\.url).flatMap(list)
            .filter { !$0.isFolder && $0.modified >= since }
        return Array(files.sorted { $0.modified > $1.modified }.prefix(60))
    }

    nonisolated private static func entry(_ url: URL) -> Entry? {
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        // An app or a bundle is one file, not a folder to walk into.
        let isFolder = values.isDirectory == true && values.isPackage != true
        return Entry(url: url, isFolder: isFolder, modified: values.contentModificationDate ?? .distantPast,
                     size: isFolder ? nil : values.fileSize)
    }
}

/// The Files tab: the places, then the open folder with its entries.
struct FilesCard: View {
    let module: ToolsModule
    var browser: FilesBrowser { module.files }

    var body: some View {
        HStack(spacing: 8) {
            NotchCard(padding: 6) {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 1) {
                        ForEach(FilesBrowser.Place.allCases) { place in
                            PlaceRow(place: place, selected: browser.place == place && browser.path.isEmpty) {
                                Haptics.tick()
                                browser.show(place)
                            }
                        }
                    }
                }
            }
            .frame(width: 168)

            NotchCard(padding: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if !browser.path.isEmpty {
                            Button { browser.back() } label: {
                                Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Theme.textSecondary)
                                    .frame(width: 22, height: 22)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PressScale())
                            .help("Back")
                        }
                        Text(browser.title).font(Theme.font(12.5, .semibold)).foregroundStyle(Theme.textPrimary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 6)
                        HStack(spacing: 2) {
                            sortOption("Date", .date)
                            sortOption("Name", .name)
                        }
                        .padding(2)
                        .background(Color.white.opacity(0.05), in: Capsule())
                        if browser.folder != nil {
                            Button("Show in Finder") { browser.reveal() }
                                .buttonStyle(PressScale())
                                .font(Theme.font(11)).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .padding(.horizontal, 4)
                    .frame(height: 24)
                    if browser.entries.isEmpty {
                        Text(browser.loading ? "Loading…" : browser.place == .recent && browser.path.isEmpty
                             ? "No files changed in the last two weeks." : "This folder is empty.")
                            .font(Theme.font(12)).foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 6)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else {
                        ScrollView(.vertical, showsIndicators: false) {
                            LazyVStack(spacing: 1) {
                                ForEach(browser.shown) { entry in
                                    FileRow(module: module, entry: entry, recent: browser.place == .recent && browser.path.isEmpty)
                                }
                            }
                        }
                        .scrollEdgeFade(bottom: 10)
                        // Into a folder the list slides in from the right, back out to the left.
                        .id(browser.shownKey)
                        .transition(.blurSlide(x: 18 * browser.direction))
                    }
                }
                // Files dropped on the list go into the open folder (not into Recent, which is no folder).
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    guard let folder = browser.folder, browser.place != .recent || !browser.path.isEmpty else { return false }
                    return browser.receive(providers, into: folder, tools: module)
                }
            }
        }
        .onAppear { browser.reload() }
    }

    private func sortOption(_ title: LocalizedStringKey, _ sort: FilesBrowser.Sort) -> some View {
        let chosen = browser.sort == sort
        return Button {
            withAnimation(Theme.snappy) { browser.sort = sort }
        } label: {
            Text(title).font(Theme.font(10.5, .semibold))
                .foregroundStyle(chosen ? Theme.textPrimary : Theme.textSecondary)
                .padding(.horizontal, 8).frame(height: 20)
                .background(Color.white.opacity(chosen ? 0.12 : 0), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(PressScale())
    }
}

private struct PlaceRow: View {
    let place: FilesBrowser.Place
    let selected: Bool
    let action: () -> Void

    var body: some View {
        HoverRow(cornerRadius: 8, restOpacity: selected ? 0.09 : 0, action: action) {
            HStack(spacing: 8) {
                Image(systemName: place.symbol).font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                    .frame(width: 18)
                Text(LocalizedStringKey(place.rawValue)).font(Theme.font(12.5, selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textBody)
                Spacer(minLength: 0)
            }
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 30)
        }
    }
}

private struct FileRow: View {
    let module: ToolsModule
    let entry: FilesBrowser.Entry
    /// In Recent: the folder it sits in instead of the size.
    let recent: Bool
    @State private var hovering = false
    @State private var targeted = false
    /// A click lands: the row gives a little and springs back.
    @State private var pressed = false

    var body: some View {
        let browser = module.files
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path))
                .resizable().frame(width: 20, height: 20)
            Text(entry.name).font(Theme.font(12.5)).foregroundStyle(Theme.textBody)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Text(detail).font(Theme.font(10.5).monospacedDigit()).foregroundStyle(Theme.textTertiary)
                .lineLimit(1).fixedSize()
            if entry.isFolder {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
        .background {
            let chosen = browser.selected == entry.url
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(chosen ? AnyShapeStyle(TaraAccent.current.opacity(0.22))
                             : AnyShapeStyle(Color.white.opacity(targeted ? 0.14 : hovering ? 0.07 : 0)))
        }
        .scaleEffect(pressed ? 0.97 : 1)
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.accent.opacity(0.8), lineWidth: 1.2)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onDrag { NSItemProvider(object: entry.url as NSURL) }
        // A folder opens on one click, like the places beside it; a file is picked on one click and
        // opens on two. Both run side by side, so no click waits to see whether a second one comes,
        // and a drag still starts.
        .simultaneousGesture(TapGesture(count: 1).onEnded {
            press()
            if entry.isFolder { browser.open(entry) } else { browser.select(entry) }
        })
        .simultaneousGesture(TapGesture(count: 2).onEnded { if !entry.isFolder { browser.open(entry) } })
        .onDrop(of: [.fileURL], isTargeted: entry.isFolder ? $targeted : nil) { providers in
            entry.isFolder && browser.receive(providers, into: entry.url, tools: module)
        }
        .contextMenu {
            Button("Open") { browser.open(entry) }
            Button("Show in Finder") { browser.reveal(entry.url) }
            Button("Copy path") { browser.copyPath(entry.url) }
            if !entry.isFolder, module.tabs.contains(.shelf) {
                Button("Add to Shelf") { module.add([entry.url]) }
            }
        }
        .help(entry.url.path)
    }

    private func press() {
        withAnimation(.spring(response: 0.12, dampingFraction: 0.7)) { pressed = true }
        Task {
            try? await Task.sleep(for: .milliseconds(110))
            withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) { pressed = false }
        }
    }

    /// "12 MB · 2 h ago", "Downloads · yesterday", a folder's "3 days ago".
    private var detail: String {
        let when = entry.modified.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
        if recent { return entry.url.deletingLastPathComponent().lastPathComponent + " · " + when }
        guard let size = entry.size else { return when }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) + " · " + when
    }
}
