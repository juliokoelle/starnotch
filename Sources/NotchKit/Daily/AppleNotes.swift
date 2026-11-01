import AppKit
import NotchCore
import Observation
import SwiftUI

/// Apple Notes through Notes' own scripting (Settings › Apple Notes, off until switched on): the
/// newest notes in the Notepad, a click shows one in Notes, and quick capture's notes copied into
/// a folder. Each script runs in its own `osascript`, off the main thread and with a time limit, so
/// the island never waits on Notes. The properties of all notes come in a few Apple events, the
/// text only for the notes on show that changed since it was read; all of it stays in memory.
/// Notes' database is never read directly, and nothing in Notes is moved or deleted.
@MainActor
@Observable
final class AppleNotesStore {
    static let shared = AppleNotesStore()
    nonisolated static let bundleID = "com.apple.Notes"

    enum Access: Equatable { case unknown, allowed, denied }
    enum Failure: Error, Equatable { case notAllowed, unavailable, timedOut, failed }

    /// Settings › Apple Notes is on (set by the app).
    @ObservationIgnored var enabled: () -> Bool = { false }
    private(set) var notes: [AppleNote] = []
    private(set) var folders: [AppleNotesFolder] = []
    private(set) var access = Access.unknown
    private(set) var reading = false
    /// Why the last read went wrong, while nothing newer came.
    private(set) var problem: Failure?
    /// Previews: made-up notes; nothing is sent to Notes.
    @ObservationIgnored private var preview = false
    @ObservationIgnored private var lastRead: Date?

    // MARK: Reading

    /// The newest notes again: at most every 15 seconds unless forced, never two reads at once.
    func refresh(force: Bool = false) {
        guard !preview, enabled(), !reading else { return }
        if !force, let lastRead, Date().timeIntervalSince(lastRead) < 15 { return }
        reading = true
        Task {
            switch await Self.readNewest() {
            case .success(let fresh):
                let merged = AppleNotesFormat.merge(fresh, cached: notes)
                access = .allowed
                problem = nil
                withAnimation(Theme.snappy) { notes = merged.notes }
                if !merged.missing.isEmpty { await readPreviews(merged.missing) }
            case .failure(let failure):
                note(failure)
            }
            reading = false
            lastRead = Date()
        }
    }

    /// The notes' first lines, for the ones that need them; a note whose text didn't come gets an
    /// empty line, so it isn't asked for again until it changes.
    private func readPreviews(_ wanted: [AppleNote]) async {
        let arguments = AppleNotesScript.contentsArguments(for: wanted, calendar: .current)
        guard case .success(let output) = await Self.run(AppleNotesScript.contents, arguments: arguments) else { return }
        let previews = AppleNotesFormat.previews(from: output)
        let asked = Set(wanted.map(\.id))
        withAnimation(Theme.snappy) {
            for index in notes.indices where asked.contains(notes[index].id) && !notes[index].locked {
                notes[index].preview = previews[notes[index].id] ?? ""
            }
        }
    }

    /// The folders quick capture can copy notes to (Settings).
    func loadFolders() {
        guard !preview, enabled() else { return }
        Task {
            switch await Self.run(AppleNotesScript.folders) {
            case .success(let output):
                folders = AppleNotesFormat.folders(from: output)
                access = .allowed
            case .failure(let failure):
                note(failure)
            }
        }
    }

    private func note(_ failure: Failure) {
        if failure == .notAllowed { access = .denied }
        problem = failure
    }

    /// Off the main thread: the list script and its answer read into the newest notes.
    private nonisolated static func readNewest() async -> Result<[AppleNote], Failure> {
        let result = await run(AppleNotesScript.list)
        return result.map { AppleNotesFormat.newest(AppleNotesFormat.notes(from: $0, calendar: .current)) }
    }

    // MARK: Showing and adding

    /// Notes comes forward on the note.
    func open(_ note: AppleNote) {
        Haptics.tick()
        open(id: note.id)
    }

    func open(id: String) {
        guard !preview else { return }
        Task { _ = await Self.run(AppleNotesScript.show, arguments: [AppleNotesScript.argument(id)]) }
    }

    func openApp() {
        Haptics.tick()
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// A capture as a new note in `folder` (Notes' default for `notesDefault`): its id, nil when it
    /// couldn't be made. Only ever adds a note; the list reads it with the next refresh.
    func create(text: String, in folder: AppleNotesFolder) async -> String? {
        guard !preview else { return "preview" }
        let arguments = [folder.id, AppleNotesFormat.body(for: text)].map(AppleNotesScript.argument)
        guard case .success(let output) = await Self.run(AppleNotesScript.create, arguments: arguments) else { return nil }
        lastRead = nil
        let id = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    // MARK: Permission

    /// The switch in Settings, on its click: macOS asks "Starnotch wants to control Notes" now.
    /// Notes opens hidden first, since macOS only asks about an app that runs. After an earlier
    /// no, macOS doesn't ask again and the answer comes at once.
    func requestAccess() async -> Access {
        guard !preview else { return .allowed }
        guard await Self.launchHidden() else {
            problem = .unavailable
            return access
        }
        let answer = await Task.detached(priority: .userInitiated) { Self.permission(ask: true) }.value
        access = answer == noErr ? .allowed : answer == OSStatus(errAEEventNotPermitted) ? .denied : .unknown
        if access == .allowed { problem = nil }
        return access
    }

    private nonisolated static func permission(ask: Bool) -> OSStatus {
        let descriptor = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        return withExtendedLifetime(descriptor) {
            guard let target = descriptor.aeDesc else { return OSStatus(procNotFound) }
            return AEDeterminePermissionToAutomateTarget(target, typeWildCard, typeWildCard, ask)
        }
    }

    // MARK: osascript

    /// Notes running; opened hidden when it wasn't (a script would open it in front).
    private nonisolated static func launchHidden() async -> Bool {
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: \.isFinishedLaunching) { return true }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        configuration.addsToRecentItems = false
        guard (try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)) != nil else { return false }
        for _ in 0..<50 {
            if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: \.isFinishedLaunching) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// One script in its own `osascript`, with Notes running.
    private nonisolated static func run(_ source: String, arguments: [String] = [], timeout: TimeInterval = 30) async -> Result<String, Failure> {
        guard await launchHidden() else { return .failure(.unavailable) }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runBlocking(source, arguments: arguments, timeout: timeout))
            }
        }
    }

    private nonisolated static func runBlocking(_ source: String, arguments: [String], timeout: TimeInterval) -> Result<String, Failure> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source] + arguments
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        guard (try? process.run()) != nil else { return .failure(.failed) }
        // Read while it runs: a long answer would fill the pipe and stall osascript.
        let answer = PipeReader(output), complaint = PipeReader(errors)
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return .failure(.timedOut)
        }
        let data = answer.wait(), message = String(decoding: complaint.wait(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            switch AppleNotesFormat.errorNumber(in: message) {
            case -1743: return .failure(.notAllowed)
            case -600, -609: return .failure(.unavailable)
            case -1712: return .failure(.timedOut)
            default: return .failure(.failed)
            }
        }
        return .success(String(decoding: data, as: UTF8.self))
    }

    // MARK: Previews

    func usePreview() {
        preview = true
        access = .allowed
        let now = Date()
        notes = [
            AppleNote(id: "p1", title: "Offsite agenda", folder: "Notes", modified: now.addingTimeInterval(-8 * 60), locked: false,
                      preview: "Day one: product review, then the roadmap for Q1."),
            AppleNote(id: "p2", title: "Groceries", folder: "Notes", modified: now.addingTimeInterval(-2 * 3600), locked: false,
                      preview: "Oat milk, lemons, coffee beans"),
            AppleNote(id: "p3", title: "Passwords for the router", folder: "Home", modified: now.addingTimeInterval(-26 * 3600), locked: true),
            AppleNote(id: "p4", title: "Talk outline", folder: "Work", modified: now.addingTimeInterval(-3 * 86_400), locked: false,
                      preview: "Open with the demo, then three lessons, then questions."),
            AppleNote(id: "p5", title: "Book list", folder: "Notes", modified: now.addingTimeInterval(-9 * 86_400), locked: false,
                      preview: "The Design of Everyday Things, Shape Up"),
        ]
        folders = [AppleNotesFolder(id: "f1", name: "Notes", account: "iCloud"), AppleNotesFolder(id: "f2", name: "Work", account: "iCloud")]
    }
}

/// Collects what a pipe delivers until it closes, on its own thread.
private final class PipeReader: @unchecked Sendable {
    private var data = Data()
    private let group = DispatchGroup()

    init(_ pipe: Pipe) {
        let handle = pipe.fileHandleForReading
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            data = handle.readDataToEndOfFile()
            group.leave()
        }
    }

    func wait() -> Data {
        group.wait()
        return data
    }
}

// MARK: Views

/// Settings › Apple Notes: the switch (macOS asks whether the app may control Notes on its click,
/// never before), what is read, and the folder note captures are copied to.
struct AppleNotesSettings: View {
    @Bindable var state: AppState
    var store: AppleNotesStore = .shared
    @State private var asking = false

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { state.settings.appleNotes }, set: { on in
                guard on else { state.settings.appleNotes = false; return }
                asking = true
                Task {
                    await Self.turnOn(state: state, store: store)
                    asking = false
                }
            })) {
                Text("Apple Notes")
                Text("Your newest notes in Tools › Notepad: title, time and first line, read from Notes and kept on this Mac. macOS asks once when you switch this on.")
            }
            .disabled(asking)
            if store.access == .denied {
                LabeledContent {
                    Button("Open Automation Settings") { PrivacyPane.open("Privacy_Automation") }
                } label: {
                    Text("\(Brand.bundleName) isn't allowed to control Notes")
                    Text("System Settings › Privacy & Security › Automation: turn on Notes under \(Brand.bundleName).")
                }
            }
            if state.settings.appleNotes {
                Picker("Note captures also go to", selection: $state.settings.appleNotesCapture) {
                    Text("Only the inbox").tag(AppleNotesFolder?.none)
                    Text("Notes' default folder").tag(AppleNotesFolder?.some(.notesDefault))
                    ForEach(folderChoices, id: \.self) { folder in
                        Text(verbatim: folder.label).tag(AppleNotesFolder?.some(folder))
                    }
                }
                .onAppear { store.loadFolders() }
            }
        } header: {
            Text("Apple Notes")
        } footer: {
            Text("Quick capture only adds new notes there; nothing in Notes is moved or deleted. Notes is read through its own scripting, never its database.")
                .foregroundStyle(.secondary)
        }
    }

    /// Switches Apple Notes on, asking macOS on this click (the switch here, All tools' Turn on).
    static func turnOn(state: AppState, store: AppleNotesStore = .shared) async {
        let access = await store.requestAccess()
        state.settings.appleNotes = access == .allowed
        if access == .allowed { store.loadFolders() }
        // Said no before: macOS won't ask again, so go to the switch itself.
        if access == .denied { PrivacyPane.open("Privacy_Automation") }
    }

    /// Notes' folders, and the one picked before while they are still being read.
    private var folderChoices: [AppleNotesFolder] {
        guard let saved = state.settings.appleNotesCapture, !saved.isNotesDefault, !store.folders.contains(saved) else { return store.folders }
        return [saved] + store.folders
    }
}

/// Tools › Notepad › Apple Notes: the newest notes with their time and first line; a click shows
/// one in Notes. Locked notes are listed without their text.
struct AppleNotesCard: View {
    let store: AppleNotesStore

    var body: some View {
        NotchCard(padding: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Your latest notes, read from Notes on this Mac.")
                        .font(Theme.font(11)).foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button("Open Notes") { store.openApp() }
                        .buttonStyle(PressScale())
                        .font(Theme.font(11)).foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal, 6)
                if store.access == .denied {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(Brand.bundleName) isn't allowed to control Notes").font(Theme.font(13, .medium)).foregroundStyle(Theme.textBody)
                        Text("Turn it on in System Settings › Privacy & Security › Automation.")
                            .font(Theme.font(11.5)).foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open Automation Settings") {
                            Haptics.tick()
                            PrivacyPane.open("Privacy_Automation")
                        }
                        .buttonStyle(PressScale())
                        .font(Theme.font(12, .medium)).foregroundStyle(Theme.accent)
                        .padding(.top, 2)
                    }
                    .padding(.horizontal, 6)
                    .padding(.top, 4)
                    Spacer(minLength: 0)
                } else if store.notes.isEmpty {
                    Text(emptyLine).font(Theme.font(12.5)).foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.top, 4)
                    Spacer(minLength: 0)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 1) {
                            ForEach(store.notes) { note in
                                AppleNoteRow(note: note) { store.open(note) }
                            }
                        }
                    }
                    .scrollEdgeFade(bottom: 10)
                }
            }
        }
        .onAppear { store.refresh() }
    }

    private var emptyLine: LocalizedStringKey {
        if store.reading { return "Reading Notes…" }
        switch store.problem {
        case .timedOut?: return "Notes took too long to answer."
        case .unavailable?: return "Notes didn't open."
        case .failed?: return "Couldn't read Notes."
        default: return "No notes yet."
        }
    }
}

private struct AppleNoteRow: View {
    let note: AppleNote
    let open: () -> Void

    var body: some View {
        HoverRow(cornerRadius: 8, help: Localization.string("Show in Notes"), action: open) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: note.title.isEmpty ? Localization.string("New Note") : note.title)
                        .font(Theme.font(12.5, .medium)).foregroundStyle(Theme.textBody)
                    Group {
                        if note.locked {
                            Label("Locked", systemImage: "lock.fill").labelStyle(.titleAndIcon)
                        } else {
                            Text(verbatim: note.preview ?? " ")
                        }
                    }
                    .font(Theme.font(11)).foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 6)
                Text(note.modified.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                    .font(Theme.font(10.5)).foregroundStyle(Theme.textTertiary).fixedSize()
            }
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 36)
        }
    }
}
