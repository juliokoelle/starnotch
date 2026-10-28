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
    /// Recordings: the four other agent tools count as found (strand agents).
    var previewMoreAgents = false
    @ObservationIgnored weak var state: AppState?
    /// Switched off before its rule is removed.
    @ObservationIgnored weak var lidAwake: LidAwakeController?

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
        // After an update: the hook script and plugin copies that are set up get this build's version.
        let installed = (paths, ledger)
        DispatchQueue.global(qos: .utility).async { SetupActions.refreshInstalledCopies(installed.0, ledger: installed.1) }
        // The other agent tools change how those tools ask: off until chosen.
        selected = Set(offered.filter { isAvailable($0) && !isSetUp($0) && !Self.moreAgentItems.contains($0) })
    }

    /// Setup items of the tools beyond Claude Code and Codex (strand agents).
    static let moreAgentItems: Set<SetupItem> = [.cursorHooks, .copilotHooks, .geminiHooks, .opencodePlugin,
                                                 .cursorApprovals, .copilotApprovals]

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
        // Strand agents: the other agent tools.
        for type in Self.moreAgents where previewMoreAgents || type.detect() { list.append(Found(name: type.displayName, symbol: "terminal")) }
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

    /// The agents among what was found (onboarding's "Your agents"): the ones the setup connects.
    var foundAgents: [Found] { found.filter { (["Claude Code", "Codex"] + Self.moreAgents.map { $0.displayName }).contains($0.name) } }

    /// Agent tools beyond Claude Code and Codex, each with its own setup item.
    static let moreAgents: [any AgentProvider.Type] = [CursorProvider.self, CopilotProvider.self, GeminiProvider.self, OpencodeProvider.self]

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
            case .lidAwake: false
            case .cursorHooks: previewMoreAgents || (CursorProvider.detect() && FileManager.default.fileExists(atPath: paths.cursorHome.path))
            case .copilotHooks: previewMoreAgents || CopilotProvider.detect()
            case .geminiHooks: previewMoreAgents || GeminiProvider.detect()
            case .opencodePlugin: previewMoreAgents || OpencodeProvider.detect()
            // Answering is offered once the tool's status is set up (or right away in recordings).
            case .cursorApprovals: previewMoreAgents || isSetUp(.cursorHooks) || isSetUp(.cursorApprovals)
            case .copilotApprovals: previewMoreAgents || isSetUp(.copilotHooks) || isSetUp(.copilotApprovals)
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
        case .cursorHooks, .copilotHooks, .geminiHooks, .cursorApprovals, .copilotApprovals:
            return paths.hookScriptSource.map { FileManager.default.fileExists(atPath: $0.path) } == true ? nil : "This build has no hook script."
        case .opencodePlugin:
            return paths.opencodePluginSource.map { FileManager.default.fileExists(atPath: $0.path) } == true ? nil : "This build has no opencode plugin."
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
                case .claudePlugin, .codexHook, .statusLine, .mcpServer, .shellHook,
                     .cursorHooks, .copilotHooks, .geminiHooks, .opencodePlugin, .cursorApprovals, .copilotApprovals:
                    let outcome = await Task.detached(priority: .userInitiated) { () -> Result<SetupLedger.Entry, Error> in
                        Result {
                            switch item {
                            case .claudePlugin: try SetupActions.installClaudePlugin(paths)
                            case .codexHook: try SetupActions.installCodexHook(paths)
                            case .statusLine: try SetupActions.installStatusLine(paths)
                            case .mcpServer: try SetupActions.installMCPServer(paths)
                            case .cursorHooks: try SetupActions.installCursorHooks(paths)
                            case .copilotHooks: try SetupActions.installCopilotHooks(paths)
                            case .geminiHooks: try SetupActions.installGeminiHooks(paths)
                            case .opencodePlugin: try SetupActions.installOpencodePlugin(paths)
                            case .cursorApprovals: try SetupActions.installCursorApprovals(paths)
                            case .copilotApprovals: try SetupActions.installCopilotApprovals(paths)
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
                case .lidAwake:
                    continue
                }
                status[item] = result
            }
            try? ledger.save(paths.ledgerFile)
        }
    }

    /// At most once per launch.
    private static var checkedClaudePlugin = false

    /// At launch, for a plugin the user set up: a registration Claude Code would skip (its folder
    /// is gone, or the plugin is missing) is repaired off the main thread; a failure stays on the
    /// setup page and isn't retried until the next launch.
    func checkClaudePlugin() {
        guard !preview, !Self.checkedClaudePlugin, isSetUp(.claudePlugin) else { return }
        Self.checkedClaudePlugin = true
        let paths = paths
        let ledger = ledger
        Task {
            let outcome = await Task.detached(priority: .utility) {
                Result { try SetupActions.checkClaudePlugin(paths, ledger: ledger) }
            }.value
            switch outcome {
            case .success(.reregister):
                if var entry = self.ledger.entry(.claudePlugin) {
                    entry.previous = paths.claudePluginCopy.path
                    entry.note = "Marketplace: \(paths.claudePluginCopy.path). Restart running sessions."
                    self.ledger.record(entry)
                    try? self.ledger.save(paths.ledgerFile)
                }
                status[.claudePlugin] = .done(Localization.string("Registered again from the app's copy. Restart running sessions."))
            case .success(.install):
                status[.claudePlugin] = .done(Localization.string("Installed again. Restart running sessions."))
            case .success:
                break
            case .failure(let error):
                status[.claudePlugin] = .failed(String(format: Localization.string("Couldn't repair the plugin's registration: %@"), String(describing: error)))
            }
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
            case .lidAwake:
                await lidAwake?.switchOffAndWait()
                if let failure = await Self.runAsAdmin(LidAwakeCommands.removeScript(), prompt: "%@ removes its rule for keeping the Mac awake with the lid closed.") {
                    // Cancelled in the dialog: nothing changed.
                    status[item] = failure.isEmpty ? .idle : .failed(failure)
                    return
                }
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
                        case .cursorHooks: try SetupActions.removeCursorHooks(paths, entry: entry)
                        case .copilotHooks: try SetupActions.removeCopilotHooks(paths)
                        case .geminiHooks: try SetupActions.removeGeminiHooks(paths, entry: entry)
                        case .opencodePlugin: try SetupActions.removeOpencodePlugin(paths)
                        case .cursorApprovals: try SetupActions.removeCursorApprovals(paths, entry: entry)
                        case .copilotApprovals: try SetupActions.removeCopilotApprovals(paths)
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

    // MARK: Keep awake with the lid closed

    /// The first time the lid switch is used: macOS asks for the password once and the rule goes
    /// in (checked by visudo first). Into the ledger whenever the file is in place, so What's set
    /// up can always remove it; when `sudo -n` still refuses it, that row says so.
    func installLidRule() async -> LidAwakeController.RuleInstall {
        guard !preview, let script = LidAwakeCommands.installScript(user: NSUserName()) else { return .failed }
        status[.lidAwake] = .running
        if let failure = await Self.runAsAdmin(script, prompt: "%@ needs your password once to keep the Mac awake with the lid closed. It may then switch sleep off and on, nothing else.") {
            status[.lidAwake] = failure.isEmpty ? nil : .failed(failure)
            return failure.isEmpty ? .cancelled : .failed
        }
        ledger.record(SetupLedger.Entry(item: .lidAwake, at: Date(),
                                        note: "\(LidAwakeCommands.ruleFile): pmset -a disablesleep 1 and 0 without a password"))
        try? ledger.save(paths.ledgerFile)
        let works = await Task.detached(priority: .userInitiated) {
            SetupActions.processRunner(LidAwakeCommands.sudo, LidAwakeCommands.checkArguments, [:]).status == 0
        }.value
        status[.lidAwake] = works ? nil : .failed(Localization.string("The rule is in place, but sudo doesn't accept it."))
        return works ? .installed : .failed
    }

    /// Runs a shell script as root behind macOS's own password dialog, in a separate `osascript`
    /// so the island keeps moving while the dialog is open. Nil when it ran; "" when the user
    /// cancelled; the message otherwise.
    private static func runAsAdmin(_ shell: String, prompt: String) async -> String? {
        let source = LidAwakeCommands.appleScript(shell: shell, prompt: String(format: Localization.string(prompt), Brand.displayName))
        let result = await Task.detached(priority: .userInitiated) {
            SetupActions.processRunner("/usr/bin/osascript", ["-e", source], [:])
        }.value
        return LidAwakeCommands.adminFailure(status: result.status, output: result.output)
            .map { $0 == LidAwakeCommands.unknownFailure ? Localization.string("macOS didn't allow it.") : $0 }
    }

    /// Recordings: the consent page as on a fresh Mac, everything offered and selected.
    func resetForPreview() {
        preview = true
        ledger = SetupLedger()
        selected = Set(offered).subtracting(Self.moreAgentItems)
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
            .init(item: .lidAwake, at: now, note: "\(LidAwakeCommands.ruleFile): pmset -a disablesleep 1 and 0 without a password"),
        ])
    }
}

// MARK: - One item

/// One thing the setup can do: what it is in one line, a switch, and what happened. Onboarding
/// lists them; `detailed` shows exactly what changes on disk.
struct SetupItemRow: View {
    @Bindable var center: SetupCenter
    let item: SetupItem
    var detailed = false

    var body: some View {
        let setUp = center.isSetUp(item)
        let reason = center.unavailableReason(item)
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(item.title)).font(.system(size: 13, weight: .medium))
                Text(LocalizedStringKey(reason ?? Self.summary(item)))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if detailed {
                    Text(item.detail(center.paths)).font(.system(size: 11)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if let status = center.status[item] {
                    switch status {
                    case .done(let note):
                        Label(note ?? Localization.string("Done"), systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.ok)
                    case .failed(let why):
                        Label(why, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11.5)).foregroundStyle(Theme.waiting)
                    case .running: ProgressView().controlSize(.mini)
                    case .idle: EmptyView()
                    }
                }
            }
            Spacer(minLength: 12)
            if setUp && center.status[item] == nil {
                Label("Set up", systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            } else {
                Toggle("", isOn: Binding(
                    get: { center.selected.contains(item) },
                    set: { on in if on { center.selected.insert(item) } else { center.selected.remove(item) } }))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Theme.accent)
                .disabled(reason != nil || center.status[item] != nil)
            }
        }
        .padding(.vertical, 3)
        .animation(Theme.snappy, value: detailed)
    }

    /// What the user gets, in one line; `SetupItem.detail` says exactly what changes.
    static func summary(_ item: SetupItem) -> String {
        switch item {
        case .claudePlugin: "Approve Claude Code's requests from the notch"
        case .codexHook: "Approve Codex from the notch; trust it once in Codex with /hooks"
        case .statusLine: "Plan limits and context in the notch; your status line keeps running"
        case .mcpServer: "Any agent can show you a line or ask you yes or no"
        case .shellHook: "Terminal commands that run 30 s or longer show in the notch"
        case .launchAtLogin: "Starts with your Mac"
        case .calendar: "macOS asks once: your next meeting, its countdown and Join"
        case .musicAutomation: "macOS asks once per player: play, pause and skip"
        case .lidAwake: "Your Mac stays awake with the lid closed while it is plugged in"
        case .cursorHooks: "Cursor's sessions in the notch"
        case .copilotHooks: "Copilot CLI's sessions in the notch, and when it waits for you"
        case .geminiHooks: "Gemini CLI's sessions in the notch, and when it waits for you"
        case .opencodePlugin: "opencode's sessions in the notch; approve its requests there"
        case .cursorApprovals: "Every shell and MCP command asks in the notch first"
        case .copilotApprovals: "Copilot's requests ask in the notch first"
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
                    Text(Localization.string(entry.item.title))
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
