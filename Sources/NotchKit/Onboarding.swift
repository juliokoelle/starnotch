import AppKit
import EventKit
import NotchCore
import SwiftUI

/// What a module needs on this Mac, and whether it's there. Modules whose source is missing hide
/// themselves (no empty ears, no error messages); the user can also switch modules off.
@MainActor
enum ModuleAvailability {
    struct Status {
        var available: Bool
        /// One line: what was found, or what is missing.
        var detail: String
    }

    static func status(_ kind: ModuleKind, settings: SwitcherSettings? = nil) -> Status {
        switch kind {
        case .agents:
            let found = FileManager.default.fileExists(atPath: Runtime.claudeDir.path)
            return Status(available: found, detail: found ? "Claude Code sessions on this Mac" : "Claude Code isn't set up on this Mac")
        case .today:
            let reminders = settings?.remindersInToday == true && RemindersSource.authorized
            if let today = Runtime.today {
                return Status(available: true, detail: "From \(type(of: today).displayName)\(reminders ? " and Reminders" : "")")
            }
            if reminders { return Status(available: true, detail: "From Apple Reminders") }
            return Status(available: false, detail: "Turn on Apple Reminders below, or add a connector (docs/SDK.md)")
        case .calendar:
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess: return Status(available: true, detail: "Your calendars, next meeting and Join")
            case .notDetermined: return Status(available: true, detail: "Asks for calendar access when you open it")
            default: return Status(available: false, detail: "Calendar access is off in System Settings")
            }
        case .nowPlaying:
            let found = PlayerBridge.bundleIDs.values.contains {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
            }
            return Status(available: found, detail: found ? "Spotify or Music" : "Spotify or Music isn't installed")
        case .dictation:
            let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: DictationModule.bundleID) != nil
            return Status(available: found, detail: found ? "Wispr Flow hands-free" : "Wispr Flow isn't installed")
        case .system:
            return Status(available: true, detail: "CPU, GPU, memory and the apps behind them")
        case .tools:
            return Status(available: true, detail: "Clipboard history, focus timer, file shelf")
        case .meeting:
            let found = FileManager.default.fileExists(atPath: Runtime.meetingAgentDir.appending(path: "agent.py").path)
            let missing = MeetingAgentSetup.missing(agentFound: found)
            return Status(available: found, detail: missing.isEmpty ? "Meeting agent: contradictions, questions, commitments"
                                                    : "Needs \(missing.joined(separator: ", ")): Settings › Meeting agent")
        }
    }

    /// Shown in the notch: available and not switched off.
    static func isShown(_ kind: ModuleKind, settings: SwitcherSettings) -> Bool {
        status(kind, settings: settings).available && !settings.disabledModules.contains(kind)
    }

    /// Order in Settings and onboarding.
    static let order: [ModuleKind] = [.agents, .calendar, .meeting, .tools, .nowPlaying, .system, .dictation, .today]
}

/// One switch per module with what it needs; used by onboarding and Settings.
struct ModuleSwitches: View {
    @Bindable var state: AppState

    var body: some View {
        ForEach(ModuleOrder.sorted(ModuleAvailability.order, by: state.settings.moduleOrder), id: \.self) { kind in
            let status = ModuleAvailability.status(kind, settings: state.settings)
            Toggle(isOn: Binding(
                get: { status.available && !state.settings.disabledModules.contains(kind) },
                set: { on in
                    var disabled = state.settings.disabledModules.filter { $0 != kind }
                    if !on { disabled.append(kind) }
                    state.settings.disabledModules = disabled
                }
            )) {
                Label {
                    Text(LocalizedStringKey(kind.title))
                    Text(LocalizedStringKey(status.detail))
                } icon: {
                    Image(systemName: ModuleSymbols.symbol(kind))
                }
            }
            .disabled(!status.available)
        }
    }
}
