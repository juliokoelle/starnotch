import AppKit
import NotchCore
import Observation
import SwiftUI

/// Quick notes: plain Markdown files in a folder, saved while typing. A note starts with a dated
/// name and takes its first line as its name when the user moves on; files the user made
/// elsewhere keep their names. The folder may be a vault or sit in iCloud: the open note is read
/// again when its file changed elsewhere, and edits made meanwhile go to a copy beside it
/// instead of over it.
@MainActor
@Observable
final class NotesStore {
    struct Note: Identifiable, Equatable {
        var url: URL
        var title: String
        var preview: String
        var modified: Date
        var id: URL { url }
    }

    var folder: URL = Brand.supportFolder.appending(path: "notes", directoryHint: .isDirectory) {
        didSet {
            guard folder != oldValue else { return }
            settle()
            selected = nil
            text = ""
            load()
        }
    }
    private(set) var notes: [Note] = []
    /// The open note; nil is a new one not saved yet.
    private(set) var selected: URL?
    /// The open note's text; saved shortly after each change.
    var text = "" {
        didSet { if text != oldValue && !loading { scheduleSave() } }
    }
    /// The editor has the keyboard: the panel stays open.
    var editing = false
    private(set) var savedAt: Date?
    /// The last save went to a copy: the file had changed elsewhere.
    private(set) var savedAsCopy = false
    @ObservationIgnored var persists = true
    /// The open file's modification date after the app last read or wrote it.
    @ObservationIgnored private var known: Date?
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// Older notes beyond this aren't listed (a big vault folder stays quick).
    static let listLimit = 300

    // MARK: Listing

    func load() {
        guard persists else { return }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let dated = files.filter { $0.pathExtension.lowercased() == NoteNaming.fileExtension }
            .map { ($0, (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .prefix(Self.listLimit)
        notes = dated.map { url, modified in
            let head = Self.head(of: url)
            let title = NoteNaming.title(of: head)
            return Note(url: url, title: title.isEmpty ? url.deletingPathExtension().lastPathComponent : title,
                        preview: NoteNaming.preview(of: head), modified: modified)
        }
        if let selected, !notes.contains(where: { $0.url == selected }) {
            self.selected = nil
            setText("")
        }
        syncOpenNote()
    }

    /// The open note's file changed elsewhere (another editor, iCloud): its text shows, unless
    /// edits wait here; those then go to a copy when they're saved.
    func syncOpenNote() {
        guard persists, let url = selected else { return }
        let disk = Self.modified(url)
        guard NoteSync.action(disk: disk, known: known, unsaved: saveTask != nil) == .reload, let fresh = Self.read(url) else { return }
        known = disk
        if fresh != text { setText(fresh) }
    }

    private static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Coordinated, so a file iCloud is still bringing down is read whole.
    private static func read(_ url: URL) -> String? {
        var text: String?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: nil) { url in
            text = try? String(contentsOf: url, encoding: .utf8)
        }
        return text
    }

    private static func write(_ text: String, to url: URL) throws {
        var coordination: NSError?
        var failure: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordination) { url in
            do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { failure = error }
        }
        if let error = coordination ?? failure { throw error }
    }

    /// The first few kilobytes, enough for the title and the preview.
    private static func head(of url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 4096)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Editing

    func open(_ note: Note) {
        guard note.url != selected else { return syncOpenNote() }
        settle()
        selected = note.url
        known = persists ? Self.modified(note.url) : nil
        setText(persists ? Self.read(note.url) ?? "" : previewTexts[note.url] ?? note.title)
    }

    /// An empty note; its file appears with the first character typed.
    func newNote() {
        Haptics.tick()
        settle()
        selected = nil
        known = nil
        setText("")
    }

    func delete(_ note: Note) {
        if note.url == selected {
            saveTask?.cancel()
            selected = nil
            setText("")
        }
        if persists { try? FileManager.default.trashItem(at: note.url, resultingItemURL: nil) }
        withAnimation(Theme.snappy) { notes.removeAll { $0.url == note.url } }
    }

    func reveal() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let selected { NSWorkspace.shared.activateFileViewerSelecting([selected]) } else { NSWorkspace.shared.open(folder) }
    }

    private func setText(_ value: String) {
        loading = true
        text = value
        loading = false
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    /// Writes the open note; the first time, its file is made.
    func save() {
        saveTask?.cancel()
        saveTask = nil
        guard persists else { return }
        let blank = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if selected == nil {
            guard !blank else { return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = NoteNaming.unique(NoteNaming.placeholder(created: Date()), taken: takenNames)
            selected = folder.appending(path: "\(name).\(NoteNaming.fileExtension)")
            known = nil
        }
        guard var url = selected else { return }
        // Changed elsewhere since the app read it: this text goes beside it, the file stays.
        let copy = NoteSync.action(disk: Self.modified(url), known: known, unsaved: true) == .conflict
        if copy {
            let name = NoteNaming.conflictName(url.deletingPathExtension().lastPathComponent, taken: takenNames)
            url = folder.appending(path: "\(name).\(NoteNaming.fileExtension)")
            selected = url
        }
        do {
            try Self.write(text, to: url)
            known = Self.modified(url)
            savedAt = Date()
            savedAsCopy = copy
            upsert(url)
        } catch {
            Log.app.error("Couldn't save the note: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Done with the open note: saved, named after its first line if it still has its dated
    /// name, or gone if it was left empty.
    func settle() {
        if saveTask != nil { save() }
        guard persists, let url = selected else { return }
        let name = url.deletingPathExtension().lastPathComponent
        guard NoteNaming.isPlaceholder(name) else { return }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? FileManager.default.removeItem(at: url)
            notes.removeAll { $0.url == url }
            selected = nil
            known = nil
            return
        }
        let base = NoteNaming.safeName(NoteNaming.title(of: text))
        guard !base.isEmpty else { return }
        let target = folder.appending(path: "\(NoteNaming.unique(base, taken: takenNames.subtracting([name]))).\(NoteNaming.fileExtension)")
        guard target != url, (try? FileManager.default.moveItem(at: url, to: target)) != nil else { return }
        selected = target
        if let index = notes.firstIndex(where: { $0.url == url }) { notes[index].url = target }
    }

    private var takenNames: Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return Set(files.map { ($0 as NSString).deletingPathExtension })
    }

    /// The saved note goes to the top of the list with its new title.
    private func upsert(_ url: URL) {
        let title = NoteNaming.title(of: text)
        let note = Note(url: url, title: title.isEmpty ? url.deletingPathExtension().lastPathComponent : title,
                        preview: NoteNaming.preview(of: text), modified: Date())
        notes.removeAll { $0.url == url }
        notes.insert(note, at: 0)
    }

    // MARK: Previews

    @ObservationIgnored private var previewTexts: [URL: String] = [:]

    func usePreview() {
        persists = false
        let base = URL(fileURLWithPath: "/preview")
        let samples: [(String, String, Double)] = [
            ("Offsite agenda", "Offsite agenda\n\nDay one: product review, then the roadmap for Q1.\nDay two: hiring plan and a long walk.", -600.0),
            ("Groceries", "Groceries\n\n- oat milk\n- lemons\n- coffee beans", -7200),
            ("Talk outline", "Talk outline\n\nOpen with the demo, then three lessons, then questions.", -86_400 * 2),
            ("Book list", "Book list\n\nThe Design of Everyday Things\nShape Up", -86_400 * 6),
        ]
        previewTexts = Dictionary(uniqueKeysWithValues: samples.map { (base.appending(path: "\($0.0).md"), $0.1) })
        notes = samples.map { title, body, age in
            Note(url: base.appending(path: "\(title).md"), title: title, preview: NoteNaming.preview(of: body), modified: Date().addingTimeInterval(age))
        }
        if let first = notes.first {
            selected = first.url
            setText(previewTexts[first.url] ?? "")
        }
    }
}

// MARK: Views

/// The notes in the Tools tab: the list on the left, the open note on the right.
struct NotesCard: View {
    @Bindable var store: NotesStore
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            NotchCard(padding: 6) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        (store.notes.count == 1 ? Text("1 note") : Text("\(store.notes.count) notes"))
                            .font(Theme.font(11)).foregroundStyle(Theme.textTertiary)
                        Spacer(minLength: 4)
                        Button {
                            store.newNote()
                            NotchPanel.takeKeyboard()
                            focused = true
                        } label: {
                            Image(systemName: "square.and.pencil").font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PressScale())
                        .help("New note")
                    }
                    .padding(.leading, 6)
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 1) {
                            ForEach(store.notes) { note in
                                NoteRow(store: store, note: note, selected: note.url == store.selected) {
                                    store.open(note)
                                }
                            }
                        }
                    }
                    .scrollEdgeFade(bottom: 10)
                }
            }
            .frame(width: 196)

            NotchCard(padding: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    ZStack(alignment: .topLeading) {
                        if store.text.isEmpty {
                            Text("Start typing. The first line is the title.")
                                .font(Theme.font(13)).foregroundStyle(Theme.textTertiary)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $store.text)
                            .font(Theme.font(13))
                            .foregroundStyle(Theme.textBody)
                            .scrollContentBackground(.hidden)
                            .scrollIndicators(.never)
                            .focused($focused)
                            .simultaneousGesture(TapGesture().onEnded { NotchPanel.takeKeyboard() })
                    }
                    HStack(spacing: 10) {
                        if let saved = store.savedAt {
                            store.savedAsCopy ? Text("Changed elsewhere, saved as a copy") : Text("Saved \(TimeText.clock(saved))")
                        } else {
                            Text("Markdown, saved as you type")
                        }
                        Spacer()
                        Button("Show in Finder") { store.reveal() }.buttonStyle(PressScale())
                    }
                    .font(Theme.font(11)).foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 4)
                }
            }
        }
        .onChange(of: focused) { _, focus in store.editing = focus }
        .onAppear { store.load() }
        // The focus goes with the view without a change: the panel must not stay held open.
        .onDisappear { store.editing = false }
    }
}

private struct NoteRow: View {
    let store: NotesStore
    let note: NotesStore.Note
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            HoverRow(cornerRadius: 8, restOpacity: selected ? 0.09 : 0, action: action) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(note.title).font(Theme.font(12.5, .medium)).foregroundStyle(Theme.textBody)
                    Text(note.modified.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                        .font(Theme.font(10.5)).foregroundStyle(Theme.textTertiary)
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .frame(height: 34)
            }
            if hovering {
                Button { store.delete(note) } label: {
                    Image(systemName: "trash").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressScale())
                .help("Move to Trash")
            }
        }
        .onHover { hovering = $0 }
    }
}

extension NotchPanel {
    /// Typing in the panel: it takes the keyboard without bringing the app forward.
    static func takeKeyboard() {
        NSApp.windows.first { $0 is NotchPanel }?.makeKey()
    }
}
