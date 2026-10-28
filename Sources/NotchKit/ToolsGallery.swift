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
            if EKEventStore.authorizationStatus(for: .reminder) == .denied {
                return Status(available: false, detail: "Reminders access is off in System Settings")
            }
            return Status(available: false, detail: "Needs Apple Reminders or a connector")
        case .calendar:
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess: return Status(available: true, detail: "Your calendars, next meeting and Join")
            case .notDetermined: return Status(available: true, detail: "Asks for calendar access when you open it")
            default: return Status(available: false, detail: "Calendar access is off in System Settings")
            }
        case .nowPlaying:
            if MediaRemoteBridge.library != nil { return Status(available: true, detail: "Any app that plays, browsers included") }
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
            return Status(available: true, detail: "Clipboard history (⌃⌥V), timers, file shelf")
        case .meeting:
            let found = FileManager.default.fileExists(atPath: Runtime.meetingAgentDir.appending(path: "agent.py").path)
            let missing = MeetingAgentSetup.missing(agentFound: found)
            return Status(available: found, detail: missing.isEmpty ? "Meeting agent: contradictions, questions, commitments"
                                                    : "Needs \(missing.joined(separator: ", ")): Settings › Meeting agent")
        }
    }

    /// Shown in the notch: available and not switched off (the Tools tab: one of its tools is on).
    static func isShown(_ kind: ModuleKind, settings: SwitcherSettings) -> Bool {
        guard status(kind, settings: settings).available, !settings.disabledModules.contains(kind) else { return false }
        if kind == .tools { return ToolFeature.allCases.contains { $0.module == .tools && ToolSwitches.isOn($0, in: settings) } }
        return true
    }
}

/// One line per tool: the gallery's words, the same in onboarding and Settings.
enum ToolInfo {
    static func symbol(_ item: ToolItem) -> String {
        switch item {
        case .module(let kind): ModuleSymbols.symbol(kind)
        case .feature(.clipboard): "doc.on.clipboard"
        case .feature(.timers): "timer"
        case .feature(.shelf): "tray.and.arrow.down"
        case .feature(.imageConverter): "photo.on.rectangle.angled"
        case .feature(.keepAwake): "cup.and.saucer"
        case .feature(.quickCapture): "square.and.pencil"
        case .feature(.lyrics): "quote.bubble"
        case .feature(.lyricsOnHover): "text.line.first.and.arrowtriangle.forward"
        case .feature(.appVolume): "slider.horizontal.3"
        }
    }

    static func title(_ item: ToolItem) -> String {
        switch item {
        case .module(.calendar): "Calendar"
        case .module(.nowPlaying): "Music"
        case .module(.meeting): "Meeting agent"
        case .module(.dictation): "Dictation"
        case .module(let kind): kind.title
        case .feature(let feature): feature.title
        }
    }

    /// What it does, in one line.
    static func line(_ item: ToolItem) -> String {
        switch item {
        case .module(.agents): "Your coding agents, their approvals and plan limits"
        case .module(.calendar): "Your next meeting, its countdown and Join"
        case .module(.nowPlaying): MediaRemoteBridge.library != nil ? "What plays on this Mac, from any app, with controls"
                                                                     : "What plays in Spotify or Music, with controls"
        case .module(.meeting): "Tara listens in meetings and remembers what was said"
        case .module(.today): "Tasks and reminders due today"
        case .module(.system): "CPU, GPU, memory and the apps behind them"
        case .module(.dictation): "Wispr Flow hands-free, from the notch"
        case .module(.tools): "Clipboard history, timers, file shelf"
        case .feature(.clipboard): "What you copied, on ⌃⌥V; never from password apps"
        case .feature(.timers): "Pomodoro, countdown and stopwatch beside the notch"
        case .feature(.shelf): "Drop files on the notch, drag them out or AirDrop them"
        case .feature(.imageConverter): "Turns images on the shelf into PNG, JPEG, HEIC or TIFF"
        case .feature(.keepAwake): "Keeps the Mac and the display awake, from the menu"
        case .feature(.quickCapture): "A note or a task in a second, on ⌃⌥N"
        case .feature(.lyrics): "The line being sung, looked up on LRCLIB by the track's name"
        case .feature(.lyricsOnHover): "The current lyric line when you hover the notch"
        case .feature(.appVolume): "A mixer for each app's volume; asks to capture system audio"
        }
    }
}

/// The Tools gallery: every tool with its symbol, one line and a switch. Onboarding shows it in
/// two cards, Settings as its own section; both switch through `ToolSwitches`.
struct ToolGallery: View {
    @Bindable var state: AppState
    var items: [ToolItem] = ToolSwitches.gallery

    var body: some View {
        ForEach(items, id: \.self) { item in
            ToolRow(item: item, state: state)
        }
    }
}

struct ToolRow: View {
    let item: ToolItem
    @Bindable var state: AppState

    var body: some View {
        let status = availability
        let on = status.available && ToolSwitches.isOn(item, in: state.settings)
        HStack(spacing: 12) {
            Image(systemName: ToolInfo.symbol(item))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(on ? Theme.accent : Color.secondary)
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(on ? 0.09 : 0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .animation(Theme.snappy, value: on)
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(ToolInfo.title(item))).font(.system(size: 13, weight: .medium))
                Text(LocalizedStringKey(status.available ? ToolInfo.line(item) : status.detail))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: Binding(get: { on }, set: { switchTo($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Theme.accent)
                .disabled(!status.available && !canAsk)
                .accessibilityLabel(Text(LocalizedStringKey(ToolInfo.title(item))))
        }
        .padding(.vertical, 3)
        .opacity(status.available || canAsk ? 1 : 0.55)
    }

    private var availability: ModuleAvailability.Status {
        guard case .module(let kind) = item else { return .init(available: true, detail: "") }
        return ModuleAvailability.status(kind, settings: state.settings)
    }

    /// Today without a connector: switching it on turns on Apple Reminders, asking macOS on the
    /// click, or opens the switch in System Settings when access was declined before.
    private var canAsk: Bool {
        item == .module(.today) && Runtime.today == nil && EKEventStore.authorizationStatus(for: .reminder) != .restricted
    }

    private func switchTo(_ on: Bool) {
        Haptics.tick()
        if on, item == .module(.today), Runtime.today == nil, !(state.settings.remindersInToday && RemindersSource.authorized) {
            RemindersSource.requestAccess { granted in
                Task { @MainActor in
                    guard granted else { PrivacyPane.open("Privacy_Reminders"); return }
                    state.settings.remindersInToday = true
                    ToolSwitches.set(item, on: true, in: &state.settings)
                }
            }
            return
        }
        ToolSwitches.set(item, on: on, in: &state.settings)
    }
}
