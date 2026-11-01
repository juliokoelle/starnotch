import AppKit
import NotchCore
import SwiftUI

/// Finished downloads in ~/Downloads (`DownloadWatch` decides). The folder's own change events
/// wake it (a vnode source, so writes into a file don't); it lists the folder a moment after the
/// last one, and every 2 s only while a new file is still growing. Nothing runs at rest. Only
/// names, file numbers and sizes are read, never a file's contents, and nothing leaves the Mac.
/// The first listing is what makes macOS ask for the Downloads folder: it runs when the user
/// switches Finished downloads on.
final class DownloadsWatcher: @unchecked Sendable {
    let folder: URL
    private let onFinished: @MainActor @Sendable ([URL]) -> Void
    private let onDenied: @MainActor @Sendable () -> Void
    // Everything below only on `queue`.
    private let queue = DispatchQueue(label: Brand.identifier + ".downloads", qos: .utility)
    private var source: DispatchSourceFileSystemObject?
    private var watch = DownloadWatch()
    private var scheduled = false
    private var running = false

    /// A moment after the last change, so a burst of renames is one listing.
    static let settle: TimeInterval = 0.8
    /// While a new file still grows.
    static let growing: TimeInterval = 2

    init(folder: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads"),
         onFinished: @escaping @MainActor @Sendable ([URL]) -> Void,
         onDenied: @escaping @MainActor @Sendable () -> Void) {
        self.folder = folder
        self.onFinished = onFinished
        self.onDenied = onDenied
    }

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            watch = DownloadWatch()
            // The baseline: what is there already never counts.
            guard scan() else { return }
            let descriptor = open(folder.path, O_EVTONLY)
            guard descriptor >= 0 else { running = false; return }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .delete, .rename],
                                                                   queue: queue)
            source.setEventHandler { [weak self] in
                guard let self, let events = self.source?.data else { return }
                // The folder itself was removed or renamed: stop rather than watch the wrong place.
                if events.contains(.delete) || events.contains(.rename) { self.halt(); return }
                self.schedule(after: Self.settle)
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            self.source = source
        }
    }

    func stop() {
        queue.async { [self] in halt() }
    }

    private func halt() {
        running = false
        source?.cancel()
        source = nil
    }

    private func schedule(after delay: TimeInterval) {
        guard running, !scheduled else { return }
        scheduled = true
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.scheduled = false
            _ = self.scan()
        }
    }

    /// Lists the folder and reports what finished; false when it can't be read.
    @discardableResult
    private func scan() -> Bool {
        guard running else { return false }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        } catch {
            // Declined in macOS's prompt, or earlier: off, with a line where to allow it.
            if (error as NSError).code == NSFileReadNoPermissionError {
                halt()
                let denied = onDenied
                Task { @MainActor in denied() }
            }
            return false
        }
        var listing: [DownloadEntry] = []
        listing.reserveCapacity(names.count)
        for name in names {
            var info = stat()
            guard lstat(folder.appending(path: name).path, &info) == 0 else { continue }
            listing.append(DownloadEntry(name: name, inode: UInt64(info.st_ino), size: Int64(info.st_size),
                                         isFile: info.st_mode & S_IFMT == S_IFREG))
        }
        let finished = watch.update(listing)
        if !finished.isEmpty {
            let urls = finished.map { folder.appending(path: $0) }
            let report = onFinished
            Task { @MainActor in report(urls) }
        }
        if watch.isSettling { schedule(after: Self.growing) }
        return true
    }
}

/// A finished download, opened from its line: Open, Show in Finder and Add to shelf. The file
/// stays where it is: the shelf only points at it, like a file dropped there.
struct DownloadCard: View {
    enum Action { case open, reveal, shelve, close }

    let url: URL
    /// The shelf is on: the third button shows.
    let canShelve: Bool
    let act: (Action) -> Void

    /// The panel body while the card shows.
    static let height: CGFloat = 76

    var body: some View {
        NotchCard(padding: 12) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable().interpolation(.high)
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Download finished").font(Theme.font(11, .medium)).foregroundStyle(Theme.textSecondary)
                    Text(verbatim: url.lastPathComponent)
                        .font(Theme.font(13, .semibold)).foregroundStyle(Theme.textPrimary)
                        .lineLimit(1).truncationMode(.middle)
                        .help(url.path)
                }
                .layoutPriority(1)
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    pill("Open", symbol: "arrow.up.forward.app", primary: true) { act(.open) }
                    pill("Show in Finder", symbol: "magnifyingglass") { act(.reveal) }
                    if canShelve { pill("Add to shelf", symbol: "tray.and.arrow.down") { act(.shelve) } }
                }
                .fixedSize()
                Button { act(.close) } label: {
                    Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold)).foregroundStyle(Theme.textSecondary)
                        .frame(width: 22, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressScale())
                .help("Close")
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func pill(_ title: LocalizedStringKey, symbol: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(Theme.font(12, .semibold))
                .foregroundStyle(primary ? Color.white : Theme.textBody)
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(primary ? Theme.accent : Color.white.opacity(0.08), in: Capsule())
        }
        .buttonStyle(PressScale())
    }
}
