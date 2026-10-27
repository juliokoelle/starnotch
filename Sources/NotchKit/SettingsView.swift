import AppKit
import EventKit
import NotchCore
import SwiftUI

struct SettingsView: View {
    @Bindable var state: AppState
    let catalog: AppCatalog
    let cast: AvatarCast
    var setup: SetupCenter?
    var jamie: JamieConnect?
    var openSetup: () -> Void = {}

    var body: some View {
        Form {
            if !state.isAccessibilityTrusted {
                Section {
                    AccessibilityNotice(state: state)
                }
            }

            Section {
                MainCharacterRow(state: state, cast: cast)
                ProjectsList(state: state, cast: cast)
            } header: {
                Text("Projects")
            } footer: {
                Text("One character per project, as the Claude app groups sessions (by working folder). Sessions in a project share the character and differ by colour.")
                    .foregroundStyle(.secondary)
            }

            Section {
                ColourScaleView(state: state, cast: cast)
            } header: {
                Text("Colour scale")
            } footer: {
                Text("Sessions show their effort level as colour, from light (low) to black (max). Two sessions on the same level differ slightly in hue and by their title.")
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(SlotPosition.allCases, id: \.self) { position in
                    SlotRow(position: position, state: state, catalog: catalog)
                }
            } header: {
                Text("Slots")
            } footer: {
                Text("Hold the notch and flick toward a slot. A module opens in the notch; an app slot quits the apps in the other slots and opens the chosen one.")
                    .foregroundStyle(.secondary)
            }

            Section("Activation") {
                LabeledContent("Notch") {
                    Text("Press and hold for \(state.settings.holdDuration, format: .number.precision(.fractionLength(2))) s")
                }
                LabeledContent("Keyboard shortcut") {
                    Text(AppState.shortcutDisplay)
                        .font(.system(.body, design: .rounded).weight(.medium))
                }
                if state.isAccessibilityTrusted {
                    LabeledContent("Accessibility") {
                        Label("Allowed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            }

            if let setup {
                Section {
                    SetupLedgerList(center: setup, openSetup: openSetup)
                } header: {
                    Text("What's set up")
                } footer: {
                    Text("Remove undoes a change exactly: the status line you had before comes back, the hooks and the plugin go.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                ProviderSwitches(state: state)
            } header: {
                Text("Providers")
            } footer: {
                Text("The agent tools found on this Mac. Their files are only read; the notch never changes a tool's settings.")
                    .foregroundStyle(.secondary)
            }

            Section {
                ToolGallery(state: state)
                if !state.settings.disabledModules.contains(.today) {
                    Toggle(isOn: Binding(
                        get: { state.settings.remindersInToday },
                        set: { on in
                            guard on else { state.settings.remindersInToday = false; return }
                            // Asked here, on the click, never before.
                            RemindersSource.requestAccess { granted in
                                Task { @MainActor in
                                    state.settings.remindersInToday = granted
                                    // Declined earlier: macOS won't ask again, so go to the switch itself.
                                    if !granted { PrivacyPane.open("Privacy_Reminders") }
                                }
                            }
                        })) {
                        Text("Apple Reminders in Today")
                        Text(RemindersSource.authorized || EKEventStore.authorizationStatus(for: .reminder) == .notDetermined
                             ? "Reminders due today and overdue. macOS asks once when you switch this on."
                             : "Reminders access is off in System Settings › Privacy & Security › Reminders.")
                    }
                }
            } header: {
                Text("Tools")
            } footer: {
                Text("A tool is off until you switch it on; the notch shows only the ones that are on. Tabs hide themselves when what they need isn't on this Mac.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Island on", selection: $state.settings.islandDisplay) {
                    ForEach(IslandDisplay.allCases, id: \.self) { display in
                        Text(LocalizedStringKey(display.title)).tag(display)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Display")
            } footer: {
                Text("On a display without a notch, the island is a small pill at the top center.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Show activity in the ears", selection: $state.settings.earsMode) {
                    ForEach(EarsMode.allCases, id: \.self) { Text(LocalizedStringKey($0.title)).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle(isOn: $state.settings.watchAutomatic) {
                    Text("Watch mode for fullscreen and video")
                    Text("The notch stays silent while a fullscreen app or a video is in front; only approvals and meetings about to start get through.")
                }
                Picker("Watch mode by hand (⌃⌥W) lasts", selection: $state.settings.watchTimer) {
                    ForEach(WatchTimer.allCases, id: \.self) { Text(LocalizedStringKey($0.title)).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Quiet")
            } footer: {
                Text("By default the notch is just the notch: figures appear when something needs you, on hover, and for a moment when something happens.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LoopsLogSettings()
            } header: {
                Text("Loops")
            } footer: {
                Text("Recurring agents and jobs that write one line per run (2026-10-26 · morning-brief · ok · note) show as loops in the Agents panel, with their schedule when a <loop>.md next to the log has a cron in its front matter.")
                    .foregroundStyle(.secondary)
            }

            Section {
                MeetingAgentSettings(state: state, jamie: jamie)
            } header: {
                Text("Meeting agent")
            } footer: {
                Text("The keys stay on this Mac, in agent.env in the app's folder, readable by you only. Keys exported in ~/.zshrc work too. Automatic uses Claude Code when it's there, else an Anthropic key, else simple rules.")
                    .foregroundStyle(.secondary)
            }

            Section("Behavior") {
                Toggle(isOn: $state.settings.keepOpenUntilClick) {
                    Text("Keep the panel open until I click outside")
                    Text("Otherwise it closes shortly after the pointer leaves it.")
                }
                Toggle(isOn: $state.settings.forceQuitEnabled) {
                    Text("Force quit apps that don't quit")
                    Text("After \(Int(state.settings.forceQuitTimeout)) seconds. Unsaved changes in those apps are lost.")
                }
                Toggle(isOn: $state.settings.localAPIEnabled) {
                    Text("Local status API")
                    Text("Scripts and loops post to the notch: POST 127.0.0.1:\(LocalAPIServer.port)/status with the token from Application Support/\(Brand.supportFolderName), or scripts/notch-status.sh.")
                }
                Toggle(isOn: Binding(get: { state.launchAtLogin }, set: { state.setLaunchAtLogin($0) })) {
                    Text("Launch at login")
                    if state.loginItemStatus == .requiresApproval {
                        Text("Approve \(Brand.bundleName) in System Settings › General › Login Items.")
                    }
                }
                if let error = state.loginItemError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                HStack {
                    Text("\(Brand.displayName) \(Self.version)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        // Fits a 14" screen; the form scrolls.
        .frame(width: 560, height: min(760, (NSScreen.main?.visibleFrame.height ?? 800) - 60))
        .onAppear {
            catalog.refresh()
            state.refreshAccessibility()
            state.refreshLoginItemStatus()
        }
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

/// The meeting agent's brain, keys and its one dependency, without a terminal or config.toml.
/// Compact: the Anthropic key and uv only.
struct MeetingAgentSettings: View {
    @Bindable var state: AppState
    /// Jamie's sync, the same row as in onboarding.
    var jamie: JamieConnect?
    var compact = false
    @State private var anthropic = MeetingAgentSetup.keys()["ANTHROPIC_API_KEY"] ?? ""
    @State private var reson8 = MeetingAgentSetup.keys()["RESON8_API_KEY"] ?? ""
    @State private var uvFound = MeetingAgentSetup.uvPath != nil
    @State private var copied = false

    var body: some View {
        if !compact, let jamie {
            JamieRow(jamie: jamie)
        }
        if !compact {
            Picker("How Tara thinks", selection: $state.settings.brain) {
                ForEach(TaraBrain.allCases, id: \.self) { brain in
                    Text(LocalizedStringKey(BrainInfo.title(brain))).tag(brain)
                }
            }
        }
        // Previews and sample data never write the real agent.env.
        SecureField("Anthropic API key", text: $anthropic, prompt: Text("sk-ant-…"))
            .onChange(of: anthropic) { _, value in if state.persists { MeetingAgentSetup.setKey("ANTHROPIC_API_KEY", value) } }
        if !compact {
            SecureField("Reson8 API key", text: $reson8, prompt: Text("for live transcription"))
                .onChange(of: reson8) { _, value in if state.persists { MeetingAgentSetup.setKey("RESON8_API_KEY", value) } }
        }
        LabeledContent("uv") {
            if uvFound {
                Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button(copied ? "Copied: paste it into Terminal" : "Install uv") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(MeetingAgentSetup.uvInstallCommand, forType: .string)
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
                    copied = true
                }
                .help(MeetingAgentSetup.uvInstallCommand)
            }
        }
        // Installed in Terminal meanwhile: the row notices without reopening Settings.
        .task {
            uvFound = MeetingAgentSetup.uvPath != nil
            while !uvFound && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                uvFound = MeetingAgentSetup.uvPath != nil
            }
        }
        if !compact, let url = URL(string: "https://console.anthropic.com/settings/keys") {
            Link("Get an Anthropic key", destination: url)
        }
    }
}

/// The run log behind the loops (RunLogConnector): picked here unless config.toml names one.
private struct LoopsLogSettings: View {
    @State private var path = UserDefaults.standard.string(forKey: RunLogConnector.defaultsKey)

    var body: some View {
        LabeledContent("Run log") {
            HStack(spacing: 8) {
                Text(path.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "None")
                    .foregroundStyle(path == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button(path == nil ? "Choose…" : "Change…") { choose() }
                if path != nil {
                    Button("Remove") {
                        UserDefaults.standard.removeObject(forKey: RunLogConnector.defaultsKey)
                        path = nil
                    }
                }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "The log your loops write to, one line per run"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: RunLogConnector.defaultsKey)
        path = url.path
    }
}

/// System Settings › Privacy & Security, opened at the switch the app needs.
enum PrivacyPane {
    static func open(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct AccessibilityNotice: View {
    let state: AppState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 20))
                .foregroundStyle(Color.accentColor)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 8) {
                Text("Allow Accessibility access")
                    .font(.headline)
                Text("The notch and the shortcut work without it. It lets Escape cancel while you hold the wheel; until then, release in the center to cancel.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Privacy & Security › Accessibility › \(Brand.bundleName). After an update, remove the entry with − and add it again.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Accessibility Settings") {
                    state.requestAccessibility()
                    state.openAccessibilitySettings()
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct SlotRow: View {
    let position: SlotPosition
    let state: AppState
    let catalog: AppCatalog
    @State private var picking = false
    /// Demo: open the picker of the bottom slot when the window appears.
    static var openOnAppear: SlotPosition?

    private var app: SlotApp? { state.settings[position] }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: Self.arrow(position))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityLabel(position.label)

            if let module = state.settings[module: position] {
                // Switched off in Tools (or not on this Mac): the wheel leaves the slot empty.
                let on = ModuleAvailability.isShown(module, settings: state.settings)
                Image(systemName: ModuleSymbols.symbol(module))
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.08), in: Circle())
                    .opacity(on ? 1 : 0.5)
                Text(LocalizedStringKey(module.title))
                    .foregroundStyle(on ? .primary : .secondary)
                Text(on ? "Module" : "Not in the notch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let app {
                Image(nsImage: AppIcons.icon(for: app, size: 64))
                    .resizable()
                    .frame(width: 26, height: 26)
                Text(app.name)
                if state.activeSlot == position {
                    Text("Active")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
            } else {
                Text("Empty")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                picking.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text(state.settings.item(at: position) == nil ? "Choose" : "Change")
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(picking ? 180 : 0))
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScale())
            .animation(Theme.snappy, value: picking)
            .popover(isPresented: $picking, arrowEdge: .leading) {
                SlotPicker(position: position, state: state, catalog: catalog) { picking = false }
            }
            .accessibilityLabel("Choose what the \(position.label.lowercased()) slot holds")
            .task {
                if Self.openOnAppear == position {
                    try? await Task.sleep(for: .milliseconds(400))
                    picking = true
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func assign(_ candidate: CatalogApp) {
        state.settings[position] = candidate.slotApp
    }

    private static func arrow(_ position: SlotPosition) -> String {
        switch position {
        case .top: "arrow.up"
        case .right: "arrow.right"
        case .bottom: "arrow.down"
        case .left: "arrow.left"
        }
    }
}

/// Known projects with their character and base colour; "Change" opens our own picker.
private struct ProjectsList: View {
    let state: AppState
    let cast: AvatarCast
    @State private var known: [String] = []

    private var projects: [String] {
        let home = AvatarCast.homeProject
        let all = Set(known).union(state.settings.projects.keys).union(home.isEmpty ? [] : [home])
        return all.sorted { ($0 == AvatarCast.homeProject ? 0 : 1, $0) < ($1 == AvatarCast.homeProject ? 0 : 1, $1) }
    }

    var body: some View {
        VStack(spacing: 2) {
            ForEach(projects, id: \.self) { project in
                ProjectRow(project: project, state: state, cast: cast)
            }
        }
        .task {
            known = await Task.detached(priority: .utility) { AgentScanner.knownProjects() }.value
            cast.register(known)
        }
    }
}

private struct ProjectRow: View {
    let project: String
    let state: AppState
    let cast: AvatarCast
    @State private var picking = false
    /// Screenshots: open this project's picker when Settings appears.
    nonisolated(unsafe) static var openOnAppear: String?

    var body: some View {
        let character = cast.character(forProject: project)
        HStack(spacing: 12) {
            AvatarView(character: character, mood: .idle, height: 30, emergeOnAppear: false, alive: false)
                .frame(width: 40, height: 32, alignment: .bottom)
            VStack(alignment: .leading, spacing: 1) {
                Text(project).font(.system(size: 13, weight: .medium))
                Text(cast.library.character(character)?.name ?? character)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                picking.toggle()
            } label: {
                Text("Change")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressScale())
            .popover(isPresented: $picking, arrowEdge: .leading) {
                ProjectStylePicker(project: project, cast: cast, state: state)
            }
        }
        .padding(.vertical, 3)
        .task {
            if Self.openOnAppear == project {
                try? await Task.sleep(for: .milliseconds(600))
                picking = true
            }
        }
    }
}

/// Character grid and base colours for one project. Buttons only, no menus.
private struct ProjectStylePicker: View {
    let project: String
    let cast: AvatarCast
    let state: AppState

    private let characterColumns = Array(repeating: GridItem(.fixed(58), spacing: 6), count: 6)

    var body: some View {
        let library = cast.library
        let current = cast.character(forProject: project)
        VStack(alignment: .leading, spacing: 12) {
            Text(project).font(.system(size: 13, weight: .semibold))
            LazyVGrid(columns: characterColumns, alignment: .leading, spacing: 6) {
                ForEach(library.characters, id: \.id) { character in
                    PickerTile(selected: character.id == current, help: character.name, size: 58) {
                        cast.setStyle(project: project, character: character.id)
                    } content: {
                        CharacterPortrait(character: character.id, height: 44)
                    }
                }
            }
            Text("Every session of this project is this character; its colour shows the session's performance level (see Colour scale).")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 400)
    }
}

/// A square choice in a picker: a character, a colour. The selected one carries the accent ring.
struct PickerTile<Content: View>: View {
    let selected: Bool
    let help: String
    var size: CGFloat = 58
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button(action: action) {
            content()
                .frame(width: size, height: size, alignment: .bottom)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .background(Color.primary.opacity(selected ? 0.10 : 0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(selected ? Theme.accent : .clear, lineWidth: 1.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A character's portrait from its pack, standing on the bottom edge.
struct CharacterPortrait: View {
    let character: String
    var height: CGFloat

    var body: some View {
        let library = AvatarLibrary.shared
        if let sprite = library.character(character)?.portrait, let image = library.image(sprite) {
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(height: height, alignment: .bottom)
        }
    }
}

/// The main character and its colour: who comes out of the notch for music, dictation and
/// capture, and who leads the projects without a pick. Onboarding and Settings share it.
struct MainCharacterPicker: View {
    let cast: AvatarCast
    @Bindable var state: AppState
    var tileSize: CGFloat = 58
    /// "Character" and "Colour" above the rows (onboarding).
    var labelled = false

    var body: some View {
        let library = cast.library
        let current = cast.main
        VStack(alignment: .leading, spacing: 14) {
            if labelled { label("Character") }
            HStack(spacing: 8) {
                ForEach(library.characters, id: \.id) { character in
                    PickerTile(selected: character.id == current, help: character.name, size: tileSize) {
                        Haptics.tick()
                        cast.setMain(character.id)
                    } content: {
                        CharacterPortrait(character: character.id, height: tileSize - 12)
                    }
                }
            }
            if labelled { label("Colour").padding(.top, 4) }
            if cast.isTintable(current) {
                let selected = state.settings.colorway ?? Colorway.builtIn[0].key
                HStack(spacing: 6) {
                    ForEach(Colorway.recipes, id: \.key) { recipe in
                        PickerTile(selected: recipe.key == selected, help: recipe.name, size: 36) {
                            Haptics.tick()
                            cast.setMainColorway(recipe.key == Colorway.builtIn[0].key ? nil : recipe.key)
                        } content: {
                            AvatarView(character: current, mood: .idle, height: 28, colorway: recipe.colorway,
                                       emergeOnAppear: false, alive: false)
                        }
                    }
                }
            } else {
                Text("\(library.character(current)?.name ?? Localization.string("This character")) keeps its own colours.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .frame(height: 36, alignment: .center)
            }
        }
    }

    private func label(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).padding(.leading, 2).padding(.bottom, -6)
    }
}

/// Settings: the main character with its colour, "Change" opens the same picker as onboarding.
private struct MainCharacterRow: View {
    @Bindable var state: AppState
    let cast: AvatarCast
    @State private var picking = false

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(character: cast.main, mood: .idle, height: 30, colorway: cast.colorway, emergeOnAppear: false, alive: false)
                .frame(width: 40, height: 32, alignment: .bottom)
            VStack(alignment: .leading, spacing: 1) {
                Text("Main character").font(.system(size: 13, weight: .medium))
                Text(cast.library.character(cast.main)?.name ?? cast.main)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                picking.toggle()
            } label: {
                Text("Change")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressScale())
            .popover(isPresented: $picking, arrowEdge: .leading) {
                MainCharacterPicker(cast: cast, state: state, tileSize: 52)
                    .padding(16)
            }
        }
        .padding(.vertical, 3)
    }
}

/// What a wheel slot holds: our own picker instead of a native menu. Modules as tiles, notch
/// apps with their icons, every other app through a search field.
private struct SlotPicker: View {
    let position: SlotPosition
    let state: AppState
    let catalog: AppCatalog
    let done: () -> Void
    @State private var query = ""
    @FocusState private var searching: Bool

    private let tiles = Array(repeating: GridItem(.fixed(78), spacing: 8), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            label("Modules")
            LazyVGrid(columns: tiles, alignment: .leading, spacing: 8) {
                ForEach(ModuleKind.selectable.filter { !state.settings.disabledModules.contains($0) }, id: \.self) { module in
                    tile(title: module.title, selected: state.settings[module: position] == module) {
                        Image(systemName: ModuleSymbols.symbol(module)).font(.system(size: 17, weight: .semibold))
                    } action: {
                        state.settings[module: position] = module
                        done()
                    }
                }
            }
            if !catalog.notchApps.isEmpty {
                label("Notch apps")
                LazyVGrid(columns: tiles, alignment: .leading, spacing: 8) {
                    ForEach(catalog.notchApps) { app in
                        tile(title: app.name, selected: state.settings[position]?.bundleID == app.bundleID) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 28, height: 28)
                        } action: {
                            state.settings[position] = app.slotApp
                            done()
                        }
                    }
                }
            }
            label("Other app")
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search apps", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searching)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            if !query.isEmpty {
                let matches = catalog.otherApps.filter { $0.name.localizedCaseInsensitiveContains(query) }.prefix(8)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(matches)) { app in
                        Button {
                            state.settings[position] = app.slotApp
                            done()
                        } label: {
                            HStack(spacing: 8) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 20, height: 20)
                                Text(app.name).font(.system(size: 13))
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 28)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PickerRowStyle())
                    }
                    if matches.isEmpty {
                        Text("No app named \u{201C}\(query)\u{201D}").font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 8)
                    }
                }
                .transition(.opacity)
            }
            Divider()
            HStack {
                Button("Choose App…") {
                    if let app = catalog.chooseApp() { state.settings[position] = app.slotApp }
                    done()
                }
                .buttonStyle(PressScale())
                .foregroundStyle(Theme.accent)
                Spacer()
                Button("Clear slot") {
                    state.settings[position] = nil
                    state.settings[module: position] = nil
                    if state.settings.activeSlot == position { state.settings.activeSlot = nil }
                    done()
                }
                .buttonStyle(PressScale())
                .foregroundStyle(.secondary)
                .disabled(state.settings.item(at: position) == nil)
            }
            .font(.system(size: 13, weight: .medium))
        }
        .padding(16)
        .frame(width: 360)
        .animation(Theme.snappy, value: query.isEmpty)
        .onAppear { catalog.refresh() }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
    }

    private func tile<Icon: View>(title: String, selected: Bool, @ViewBuilder icon: () -> Icon,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                icon().frame(height: 28)
                Text(title).font(.system(size: 11.5, weight: selected ? .semibold : .regular)).lineLimit(1)
            }
            .foregroundStyle(selected ? Theme.accent : .primary)
            .frame(width: 78, height: 64)
            .background(selected ? Theme.accent.opacity(0.14) : Color.primary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? Theme.accent : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct PickerRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.0001),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Launch-option hook for screenshots of the slot picker.
enum SlotRowDemo {
    @MainActor static func open(_ position: SlotPosition) { SlotRow.openOnAppear = position }
    @MainActor static func openProject(_ project: String) { ProjectRow.openOnAppear = project }
}

/// "Colour by" switch and a colorway per performance level, all buttons (no menus).
private struct ColourScaleView: View {
    let state: AppState
    let cast: AvatarCast
    @State private var editing: PerformanceLevel?
    @Namespace private var toggle

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Colour by").font(.system(size: 13))
                Spacer()
                HStack(spacing: 2) {
                    option("Performance", .performance)
                    // A character that keeps its colours can't be told apart by colour.
                    if cast.isTintable(cast.main) { option("Session", .session) }
                }
                .padding(2)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            if cast.colourBy == .performance {
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(PerformanceLevel.allCases, id: \.self) { level in
                        let key = cast.colourScale[level] ?? PerformanceLevel.defaultScale[level]!
                        // The lead character's own look for the level, unless a colour is set.
                        let fixed = !cast.isTintable(cast.main)
                        let own = cast.isCustomized(level) && !fixed ? nil : cast.variant(of: cast.main, level: level)
                        Button { editing = level } label: {
                            VStack(spacing: 4) {
                                AvatarView(character: cast.main, mood: .working, height: 38,
                                           colorway: own.map { $0.colorway.map(Colorway.named) ?? Colorway() } ?? Colorway.named(key),
                                           emergeOnAppear: false, alive: false, level: own == nil ? nil : level)
                                    .frame(width: 66, height: 44, alignment: .bottom)
                                Text(level.title).font(.system(size: 11.5, weight: .medium))
                                Text(own.map { $0.name ?? "Own" } ?? Colorway.title(key))
                                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(width: 72, height: 86)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressScale())
                        .disabled(fixed)
                        .help(fixed ? "\(cast.library.character(cast.main)?.name ?? Localization.string("This character")) keeps its colours; the effort shows in its look" : "")
                        .popover(isPresented: Binding(get: { editing == level }, set: { if !$0 { editing = nil } }), arrowEdge: .bottom) {
                            ColorwayPicker(level: level, selected: cast.isCustomized(level) ? key : nil, character: cast.main,
                                           own: cast.variant(of: cast.main, level: level)) { picked in
                                cast.setColour(picked ?? PerformanceLevel.defaultScale[level]!, for: level)
                                editing = nil
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func option(_ title: String, _ mode: ColourBy) -> some View {
        let selected = cast.colourBy == mode
        return Button {
            withAnimation(Theme.snappy) { cast.setColourBy(mode) }
        } label: {
            Text(title)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.accent : .secondary)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Theme.accent.opacity(0.14))
                            .matchedGeometryEffect(id: "colourBy", in: toggle)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
    }
}

private struct ColorwayPicker: View {
    let level: PerformanceLevel
    /// The colour set for the level; `nil` = the default (the character's own look, if it has one).
    let selected: String?
    let character: String
    let own: AvatarLibrary.Character.LevelVariant?
    let pick: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(level.title) effort").font(.system(size: 13, weight: .semibold))
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(70), spacing: 6), count: 4), spacing: 6) {
                if let own {
                    Button { pick(nil) } label: {
                        VStack(spacing: 3) {
                            AvatarView(character: character, mood: .working, height: 40,
                                       colorway: own.colorway.map(Colorway.named) ?? Colorway(),
                                       emergeOnAppear: false, alive: false, level: level)
                                .frame(width: 64, height: 44, alignment: .bottom)
                            Text(own.name ?? "Own").font(.system(size: 10.5))
                                .foregroundStyle(selected == nil ? Theme.accent : .secondary)
                        }
                        .frame(width: 70, height: 66)
                        .background(Color.primary.opacity(selected == nil ? 0.10 : 0.04),
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(selected == nil ? Theme.accent : .clear, lineWidth: 1.5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScale())
                    .help("The character's own look for this level")
                }
                ForEach(Colorway.recipes, id: \.key) { recipe in
                    Button { pick(recipe.key) } label: {
                        VStack(spacing: 3) {
                            AvatarView(character: character, mood: .idle, height: 40, colorway: recipe.colorway,
                                       emergeOnAppear: false, alive: false)
                                .frame(height: 44, alignment: .bottom)
                            Text(recipe.name).font(.system(size: 10.5))
                                .foregroundStyle(recipe.key == selected ? Theme.accent : .secondary)
                        }
                        .frame(width: 70, height: 66)
                        .background(Color.primary.opacity(recipe.key == selected ? 0.10 : 0.04),
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(recipe.key == selected ? Theme.accent : .clear, lineWidth: 1.5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScale())
                }
            }
        }
        .padding(14)
    }
}

/// One switch per agent tool found on this Mac, and the visible setup for Codex approvals.
private struct ProviderSwitches: View {
    @Bindable var state: AppState
    @State private var copied = false

    var body: some View {
        let detected = AgentScanner.providerTypes.filter { $0.detect() }
        if detected.isEmpty {
            Text("No agent tools found (Claude Code, Codex).").foregroundStyle(.secondary)
        }
        ForEach(detected.map { ($0.id, $0.displayName) }, id: \.0) { id, name in
            Toggle(isOn: Binding(
                get: { !state.settings.disabledProviders.contains(id) },
                set: { on in
                    var off = Set(state.settings.disabledProviders)
                    if on { off.remove(id) } else { off.insert(id) }
                    state.settings.disabledProviders = off.sorted()
                })) {
                Text(name)
                Text(id == CodexProvider.id
                     ? "Sessions, subagents, context and plan limits from ~/.codex."
                     : "Sessions and subagents from ~/.claude; titles and status from the Claude app when it's installed.")
            }
        }
        if detected.contains(where: { $0.id == CodexProvider.id }) {
            let setup = CodexProvider().approvalSetup
            LabeledContent {
                Button(copied ? "Copied" : "Copy command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(setup.install, forType: .string)
                    copied = true
                }
            } label: {
                Text(setup.title)
                Text(setup.note ?? "")
            }
        }
    }
}
