import AppKit
import EventKit
import NotchCore
import Observation
import SwiftUI

/// The one-click setup: what this Mac has, what the app can set up for it, and what it did.
/// Nothing runs without the user's click on "Set up"; every change keeps a backup and has a
/// Remove button on the "What's set up" page.
@MainActor
@Observable
final class SetupCenter {
    enum Status: Equatable { case idle, running, done(String?), failed(String) }

    let paths: SetupPaths
    private(set) var ledger: SetupLedger
    var selected: Set<SetupItem> = []
    private(set) var status: [SetupItem: Status] = [:]
    /// Recordings: show the page, never act.
    var preview = false
    @ObservationIgnored weak var state: AppState?

    init(state: AppState?) {
        self.state = state
        let resources = Bundle.main.resourceURL
        let integrations = resources?.appending(path: "integrations")
        paths = SetupPaths(
            home: FileManager.default.homeDirectoryForCurrentUser,
            support: Brand.supportFolder,
            integrations: integrations.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil },
            bridgeScript: resources?.appending(path: "statusline-bridge.sh"))
        ledger = SetupLedger.load(paths.ledgerFile)
        selected = Set(offered.filter { isAvailable($0) && !isSetUp($0) })
    }

    // MARK: What this Mac has

    struct Found: Identifiable {
        var id: String { name }
        var name: String
        var symbol: String
    }

    var found: [Found] {
        var list: [Found] = []
        if FileManager.default.fileExists(atPath: paths.home.appending(path: ".claude").path) { list.append(Found(name: "Claude Code", symbol: "terminal")) }
        if CodexProvider.detect() { list.append(Found(name: "Codex", symbol: "chevron.left.forwardslash.chevron.right")) }
        list.append(Found(name: "Calendar", symbol: "calendar"))
        let players = PlayerBridge.bundleIDs.sorted(by: { $0.value < $1.value })
            .filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.value) != nil }
            .compactMap { PlayerBridge.names[$0.key] }
        if !players.isEmpty { list.append(Found(name: players.joined(separator: ", "), symbol: "music.note")) }
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: DictationModule.bundleID) != nil {
            list.append(Found(name: "Wispr Flow", symbol: "mic"))
        }
        return list
    }

    /// The items this Mac can use, in page order.
    var offered: [SetupItem] {
        SetupItem.allCases.filter { item in
            switch item {
            case .claudePlugin, .statusLine: FileManager.default.fileExists(atPath: paths.home.appending(path: ".claude").path)
            case .codexHook: CodexProvider.detect()
            case .mcpServer: FileManager.default.fileExists(atPath: paths.home.appending(path: ".claude").path) || CodexProvider.detect()
            case .shellHook: (ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh").hasSuffix("zsh")
            case .launchAtLogin, .calendar: true
            case .musicAutomation: PlayerBridge.bundleIDs.values.contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
            }
        }
    }

    /// Can be set up now (the claude command is there, the integrations are bundled …).
    func isAvailable(_ item: SetupItem) -> Bool { unavailableReason(item) == nil }

    func unavailableReason(_ item: SetupItem) -> String? {
        if preview { return nil }
        switch item {
        case .claudePlugin: return paths.claudeBinary == nil ? "The claude command wasn't found." : nil
        case .codexHook: return paths.integrations == nil ? "This build has no Codex installer." : nil
        case .statusLine: return paths.bridgeScript.map { FileManager.default.fileExists(atPath: $0.path) } == true ? nil : "This build has no bridge script."
        case .mcpServer:
            if paths.claudeBinary == nil && paths.codexBinary == nil { return "The claude or codex command wasn't found." }
            return paths.uvBinary == nil ? "Needs uv: Settings › Meeting agent › Install uv." : nil
        default: return nil
        }
    }

    func isSetUp(_ item: SetupItem) -> Bool {
        switch item {
        case .launchAtLogin: return state?.launchAtLogin ?? false
        case .calendar: return EKEventStore.authorizationStatus(for: .event) != .notDetermined
        default: return ledger.entry(item) != nil
        }
    }

    // MARK: Set up

    /// Runs the selected items in page order (permissions last, so their prompts come one after
    /// another at the end).
    func setUp(_ items: Set<SetupItem>) {
        guard !preview else {
            for item in items { status[item] = .done(nil) }
            return
        }
        let order = offered.filter { items.contains($0) && !isSetUp($0) }
        for item in order { status[item] = .running }
        // The MCP server runs from the agent's copy in the support folder.
        if order.contains(.mcpServer) { _ = MeetingAgentSetup.ensureInstalled() }
        let paths = paths
        Task {
            for item in order {
                let result: Status
                switch item {
                case .claudePlugin, .codexHook, .statusLine, .mcpServer, .shellHook:
                    let outcome = await Task.detached(priority: .userInitiated) { () -> Result<SetupLedger.Entry, Error> in
                        Result {
                            switch item {
                            case .claudePlugin: try SetupActions.installClaudePlugin(paths)
                            case .codexHook: try SetupActions.installCodexHook(paths)
                            case .statusLine: try SetupActions.installStatusLine(paths)
                            case .mcpServer: try SetupActions.installMCPServer(paths)
                            default: try SetupActions.installShellHook(paths)
                            }
                        }
                    }.value
                    switch outcome {
                    case .success(let entry):
                        ledger.record(entry)
                        result = .done(entry.note)
                    case .failure(let error):
                        result = .failed(String(describing: error))
                    }
                case .launchAtLogin:
                    state?.setLaunchAtLogin(true)
                    if state?.launchAtLogin == true {
                        ledger.record(SetupLedger.Entry(item: .launchAtLogin, at: Date()))
                        result = .done(state?.loginItemStatus == .requiresApproval ? "Approve it in System Settings › Login Items." : nil)
                    } else {
                        result = .failed(state?.loginItemError ?? "macOS didn't allow it.")
                    }
                case .calendar:
                    let granted = (try? await EKEventStore().requestFullAccessToEvents()) ?? false
                    ledger.record(SetupLedger.Entry(item: .calendar, at: Date(), note: granted ? "Allowed" : "Not allowed"))
                    result = granted ? .done(nil) : .failed("Not allowed. You can turn it on in System Settings › Privacy & Security › Calendars.")
                case .musicAutomation:
                    result = .done(Self.askMusicPermission())
                    ledger.record(SetupLedger.Entry(item: .musicAutomation, at: Date(), note: "Asked for running players"))
                }
                status[item] = result
            }
            try? ledger.save(paths.ledgerFile)
        }
    }

    /// Asks macOS for permission to control the players that run now; the others are asked the
    /// first time they play (an Apple event to a closed app would launch it).
    static func askMusicPermission() -> String {
        var asked: [String] = []
        for (source, id) in PlayerBridge.bundleIDs where !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty {
            var target = AEAddressDesc()
            let status = id.withCString { pointer in
                AECreateDesc(typeApplicationBundleID, pointer, strlen(pointer), &target)
            }
            guard status == noErr else { continue }
            _ = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, true)
            AEDisposeDesc(&target)
            asked.append(PlayerBridge.names[source] ?? id)
        }
        return asked.isEmpty ? "macOS asks the first time a player plays." : "Asked for \(asked.joined(separator: " and "))."
    }

    // MARK: Remove

    func remove(_ item: SetupItem) {
        guard !preview, let entry = ledger.entry(item) else { return }
        let paths = paths
        status[item] = .running
        Task {
            let outcome: Result<Void, Error>
            switch item {
            case .launchAtLogin:
                state?.setLaunchAtLogin(false)
                outcome = .success(())
            default:
                outcome = await Task.detached(priority: .userInitiated) {
                    Result {
                        switch item {
                        case .claudePlugin: try SetupActions.removeClaudePlugin(paths)
                        case .codexHook: try SetupActions.removeCodexHook(paths)
                        case .statusLine: try SetupActions.removeStatusLine(paths, entry: entry)
                        case .shellHook: try SetupActions.removeShellHook(paths)
                        case .mcpServer: try SetupActions.removeMCPServer(paths)
                        default: break
                        }
                    }
                }.value
            }
            switch outcome {
            case .success:
                ledger.forget(item)
                status[item] = .idle
            case .failure(let error):
                status[item] = .failed(String(describing: error))
            }
            try? ledger.save(paths.ledgerFile)
        }
    }

    /// Recordings: the consent page as on a fresh Mac, everything offered and selected.
    func resetForPreview() {
        preview = true
        ledger = SetupLedger()
        selected = Set(offered)
    }

    /// Recordings: a page as it looks after setting up.
    func usePreviewLedger() {
        preview = true
        let now = Date()
        ledger = SetupLedger(entries: [
            .init(item: .claudePlugin, at: now, previous: SetupPaths.marketplaceRepo, note: "Marketplace: juliokoelle/starnotch. Restart running sessions."),
            .init(item: .codexHook, at: now, backup: "~/.codex/hooks.json.bak-starnotch-20261024-101500", note: "Trust it once in Codex: /hooks"),
            .init(item: .statusLine, at: now, backup: "backups/claude-settings.json-20261024-101500", previous: "{}", note: "Your status line keeps running after the bridge."),
            .init(item: .shellHook, at: now, backup: "backups/zshrc-20261024-101500", note: "New terminal windows pick it up."),
            .init(item: .launchAtLogin, at: now),
            .init(item: .calendar, at: now, note: "Allowed"),
        ])
    }
}

// MARK: - The consent page

/// Exactly what will be set up, with one switch each; nothing happens before the click.
struct SetupConsentView: View {
    @Bindable var center: SetupCenter
    var onClose: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Set up \(Brand.displayName)").font(.system(size: 22, weight: .semibold))
                Text("Found on this Mac:").foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(center.found) { item in
                        Label(item.name, systemImage: item.symbol)
                            .font(.caption)
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }
            }
            Form {
                Section {
                    ForEach(center.offered, id: \.self) { item in row(item) }
                } header: {
                    Text("This will be set up")
                } footer: {
                    Text("Every change keeps a backup and can be removed in Settings › What's set up. Nothing leaves this Mac.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            if center.offered.contains(.codexHook) {
                Label("One step stays with you: in Codex, type /hooks once and trust the Starnotch hook. Codex skips hooks you haven't trusted.",
                      systemImage: "hand.point.right")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Not now") { onClose?() }
                Spacer()
                let pending = center.selected.filter { !center.isSetUp($0) }
                let everything = Set(center.offered.filter { center.isAvailable($0) && !center.isSetUp($0) })
                if center.status.values.contains(where: { if case .running = $0 { true } else { false } }) {
                    ProgressView().controlSize(.small)
                } else if !center.status.isEmpty, pending.allSatisfy({ center.status[$0] != nil }) {
                    Button("Done") { onClose?() }.keyboardShortcut(.defaultAction)
                } else {
                    Button(pending == everything ? "Set up everything" : "Set up \(pending.count) selected") {
                        center.setUp(pending)
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(pending.isEmpty)
                }
            }
        }
        .padding(22)
        .frame(width: 560)
    }

    @ViewBuilder private func row(_ item: SetupItem) -> some View {
        let setUp = center.isSetUp(item)
        let reason = center.unavailableReason(item)
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                Text(reason ?? item.detail(center.paths)).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let status = center.status[item] {
                    switch status {
                    case .done(let note): Label(note ?? "Done", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
                    case .failed(let why): Label(why, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                    case .running: ProgressView().controlSize(.mini)
                    case .idle: EmptyView()
                    }
                }
            }
            Spacer()
            if setUp && center.status[item] == nil {
                Label("Set up", systemImage: "checkmark").font(.callout).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
            } else {
                Toggle("", isOn: Binding(
                    get: { center.selected.contains(item) },
                    set: { on in if on { center.selected.insert(item) } else { center.selected.remove(item) } }))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(reason != nil || center.status[item] != nil)
            }
        }
    }
}

// MARK: - What's set up

/// Settings: each change the setup made, with its backup and a Remove that undoes it exactly.
struct SetupLedgerList: View {
    @Bindable var center: SetupCenter
    var openSetup: () -> Void

    var body: some View {
        if center.ledger.entries.isEmpty {
            Text("Nothing yet. The setup page sets up approvals, plan limits and more in one click.")
                .foregroundStyle(.secondary)
        }
        ForEach(center.ledger.entries, id: \.item) { entry in
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.item.title)
                    Text(lines(entry)).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if case .failed(let why) = center.status[entry.item] {
                        Text(why).font(.callout).foregroundStyle(.orange)
                    }
                }
                Spacer()
                if entry.item.isRemovable {
                    Button("Remove") { center.remove(entry.item) }
                        .disabled(center.status[entry.item] == .running)
                } else {
                    Button("System Settings…") { openPrivacy(entry.item) }
                }
            }
        }
        HStack {
            Spacer()
            Button("Set up more…", action: openSetup)
        }
    }

    private func lines(_ entry: SetupLedger.Entry) -> String {
        var parts = ["Since \(entry.at.formatted(date: .abbreviated, time: .shortened))"]
        if let note = entry.note { parts.append(note) }
        if let backup = entry.backup { parts.append("Backup: \((backup as NSString).abbreviatingWithTildeInPath)") }
        return parts.joined(separator: " · ")
    }

    private func openPrivacy(_ item: SetupItem) {
        let anchor = item == .calendar ? "Privacy_Calendars" : "Privacy_Automation"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(url) }
    }
}

/// Recordings: the "What's set up" section on its own, as Settings shows it.
@MainActor
enum SetupLedgerWindow {
    private static var window: NSWindow?

    static func show(center: SetupCenter) {
        let view = Form {
            Section {
                SetupLedgerList(center: center, openSetup: {})
            } header: {
                Text("What's set up")
            } footer: {
                Text("Remove undoes a change exactly: the status line you had before comes back, the hooks and the plugin go.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = "\(Brand.displayName) Settings"
        window.styleMask = [.titled, .closable]
        window.center()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

@MainActor
final class SetupWindowController {
    private let center: SetupCenter
    private var window: NSWindow?
    var onClose: (() -> Void)?

    init(center: SetupCenter) { self.center = center }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SetupConsentView(center: center) { [weak self] in self?.close() })
            hosting.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = Brand.displayName
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func close() {
        window?.close()
        onClose?()
    }
}
