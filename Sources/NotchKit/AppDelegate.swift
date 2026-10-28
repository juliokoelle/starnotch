import AppKit
import SwiftUI
import NotchCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options = LaunchOptions()
    private var state: AppState!
    private var wheel: WheelController!
    private var notch: NotchController!
    private var notchModel: NotchModel!
    private var statusItem: StatusItemController!
    private var settingsWindow: SettingsWindowController!
    private var hotKey: HotKey?
    private var agents: AgentsModule!
    private var calendar: CalendarModule!
    private var joinHotKey: HotKey?
    private var api: LocalAPIServer?
    private var captureHotKey: HotKey?
    private var inboxHotKey: HotKey?
    private var watchHotKey: HotKey?
    private var clipboardHotKey: HotKey?
    private let watchMode = WatchMode()
    private var previewDirector: PreviewDirector?
    private var agendaPreview: AgendaPreview?
    private var setup: SetupCenter!
    private var onboarding: OnboardingWindowController?
    private var cast: AvatarCast!
    /// Every module built, shown or not; `NotchModel.modules` holds the shown ones.
    private var allModules: [NotchModule] = []
    private var system: SystemModule?
    private var meeting: MeetingModule?
    private var tools: ToolsModule?
    /// The Tools module watches the clipboard (not in previews).
    private var toolsLive = false
    private let headphones = HeadphoneBattery()
    private var companion: MeetingCompanion?
    private let battery = BatteryMonitor()
    private let keepAwake = KeepAwake()
    private var lidAwake: LidAwakeController?
    private var shell: ShellMonitor?
    private let updater = Updater()
    private var approvals: ApprovalCenter?
    /// Daily tools (strand daily): weather, day progress, notes, sleep and recovery.
    private let daily = DailyStore.shared
    /// Notes (vault strand): watches the notes folder, keeps Tara's snapshot and Today current.
    private var vaultLive: VaultLive?
    // Command palette and agents inbox (strand cmdk).
    private var paletteHotKey: HotKey?
    private var agentsInboxHotKey: HotKey?
    // Ask Tara (strand ask)
    private var ask: AskTara?
    private var askHotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        state = AppState()
        state.persists = options.preview == nil && !options.sampleData
        if options.demoSlots { applyDemoSlots() }

        let cast = AvatarCast(state: state)
        self.cast = cast
        let agents = AgentsModule(cast: cast)
        let dictation = DictationModule(cast: cast)
        let preview = options.preview != nil
        // --preview and --sample-data use made-up data and never ask for permissions.
        let sample = preview || options.sampleData
        let calendar = sample ? CalendarModule(mock: true, mockLead: 95 * 60) : CalendarModule(mock: options.mockCalendar)
        let music = NowPlayingModule(cast: cast)
        self.agents = agents
        self.calendar = calendar
        // The agenda (day band, briefing) shows `CalendarModule`'s events; `CalendarModule` stays
        // the EventKit source (focus blocks, call links, reminder, ⌃⌥J).
        let samples: SampleConnector? = sample ? SampleConnector() : nil
        let agendaPreview: AgendaPreview? = AgendaPreview.handles(options.preview)
            ? AgendaPreview(vault: options.preview?.contains("vault") == true) : nil
        self.agendaPreview = agendaPreview
        let people: (any PeopleProvider)? = samples ?? Runtime.people
        let agenda = agendaPreview?.agenda ?? AgendaModule(variant: .b, people: people, source: sample ? nil : calendar)
        // Today: the connector's list, Apple Reminders when switched on, or both.
        let reminders = RemindersSource()
        reminders.base = { Runtime.today }
        reminders.enabled = { [weak self] in self?.state.settings.remindersInToday ?? false }
        let todayProvider: (any TodayProvider)? = samples ?? reminders
        let today = agendaPreview?.today ?? todayProvider.map { TodayModule(provider: $0, agenda: agenda) }
        let system = SystemModule()
        system.cast = cast
        self.system = system
        let meeting = MeetingModule()
        self.meeting = meeting
        meeting.jamie.simulated = sample
        // Meetings came in from Jamie: the Meeting agent goes on, it has something to work with.
        meeting.onJamieSynced = { [weak self] _ in
            guard let self else { return }
            ToolSwitches.set(.module(.meeting), on: true, in: &self.state.settings)
        }
        state.onBrainChanged = { [weak meeting] in meeting?.brainChanged() }
        // MARK: Notes (vault strand)
        // The notes folder is watched (no polling): a changed note rewrites Tara's snapshot and
        // reloads Today; a folder picked in Settings makes Today available at once. Previews show
        // a made-up vault and write nothing.
        if preview {
            let name = options.preview ?? ""
            VaultSetup.preview = VaultSamples.connector(empty: !name.contains("notes"), picked: name == "notes-settings-edit")
        }
        if !sample, let vault = Runtime.vault {
            let live = VaultLive(connector: vault)
            live.onChange = { [weak today] in today?.reload() }
            live.onReconfigure = { [weak self] in self?.state.onModulesChanged?() }
            live.start()
            vaultLive = live
        }
        // MARK: -

        let tools = ToolsModule()
        self.tools = tools
        allModules = [agents, agenda, music, system, dictation, meeting, tools]
        if let today { allModules.insert(today, at: 1) }
        notchModel = NotchModel(modules: shownModules(sample: sample))
        // --preview: mock data for screenshots and recordings; the features themselves are live.
        notchModel.previewFeatures = preview
        agents.music = music
        notchModel.cast = cast
        notchModel.onReorder = { [weak self] visible in
            guard let self else { return }
            self.state.settings.moduleOrder = ModuleOrder.saved(visible: visible, previous: self.state.settings.moduleOrder)
        }
        notch = NotchController(model: notchModel, display: { [weak self] in self?.state.settings.islandDisplay ?? .automatic })
        today?.onOpenCalendar = { [weak self] in
            guard let self else { return }
            Haptics.tick()
            self.notchModel.direction = 1
            withAnimation(Theme.snappy) { self.notchModel.module = .calendar }
        }
        state.onModulesChanged = { [weak self] in
            guard let self else { return }
            withAnimation(Theme.snappy) { self.notchModel.modules = self.shownModules(sample: sample) }
            self.applyTools()
        }
        state.onDisplayChanged = { [weak self] in self?.notch.placeOnScreen() }
        notch.keepsOpen = { [weak self] in
            (self?.state.settings.keepOpenUntilClick ?? false) || self?.notchModel.approvals?.current != nil
        }
        let approvals = ApprovalCenter()
        notchModel.approvals = approvals
        approvals.onShow = { [weak self] in
            guard let self else { return }
            // Watching: one small line instead of opening over the video; a click opens the card.
            if self.notchModel.watching {
                self.notch.sneak(Sneak(visual: .symbol("hand.raised.fill", tint: .waiting), title: "Approval waiting",
                                       duration: 4), key: "approval", urgent: true)
            } else {
                self.notch.showApproval()
            }
        }
        approvals.onEmpty = { [weak self] in
            // The inbox stays open on what else waits (it closes itself when nothing does); the
            // palette never showed the prompt, so it stays as it is.
            guard let self, ![.inbox, .palette].contains(self.notchModel.interaction) else { return }
            self.notch.collapse()
        }
        approvals.onChange = { [weak agents] requests in agents?.setPendingApprovals(requests) }
        // Strand agents: status hooks of Cursor, Copilot CLI, Gemini CLI and opencode arrive on the approvals socket.
        approvals.onHookEvent = { [weak agents] data in agents?.ingestHook(data) }
        agents.onLimitAlert = { [weak self] tool, window, used, pace in
            self?.notch.sneak(Sneak(visual: .symbol("gauge.with.dots.needle.67percent", tint: used >= 90 ? .critical : .waiting),
                                    // "Claude full at 14:20 · 82 %" when the pace says so, else "Claude 82 % · lasts".
                                    title: pace?.hasPrefix("full") == true ? "\(tool) \(pace!)" : "\(tool) \(Int(used.rounded())) %",
                                    detail: pace?.hasPrefix("full") == true ? "\(Int(used.rounded())) %" : pace ?? window, duration: 4),
                              key: "limit.\(tool).\(window)")
        }
        if let bundled = Bundle.main.resourceURL?.appending(path: "integrations/claude-code/starnotch-approvals"),
           FileManager.default.fileExists(atPath: bundled.path) {
            CodexProvider.integrationFolder = bundled.path
        }
        if !preview && !options.sampleData { approvals.start() }
        self.approvals = approvals
        system.onAlert = { [weak self] title, culprit, level in
            self?.notch.sneak(Sneak(visual: .symbol(level == .critical ? "exclamationmark.triangle.fill" : "gauge.with.dots.needle.67percent",
                                                    tint: level == .critical ? .critical : .waiting),
                                    title: title, detail: culprit, duration: 3.4),
                              key: "system.alert")
        }
        agents.onSubagentFinished = { [weak self, weak agents] parent, sub in
            guard let self, let agents else { return }
            self.notch.sneak(Sneak(visual: .character(agents.character(of: parent), sub.status == .failed ? .failed : .finished,
                                                      hue: agents.hue(of: parent)),
                                   title: "\(sub.name) \(sub.status == .failed ? "failed" : "done")",
                                   detail: "subagent of \(parent.displayTitle)"),
                             key: "subagent.\(sub.id)")
        }
        agents.onFinished = { [weak self, weak agents] agent in
            guard let self, let agents else { return }
            self.notch.sneak(Sneak(visual: .character(agents.character(of: agent), .finished, hue: agents.hue(of: agent)),
                                   title: agent.project, detail: "done · your turn"),
                             key: "agent.\(agent.id)")
        }
        notch.startMonitoring()
        notch.isLocked = options.expand != nil || options.tour || preview
        agents.start()
        calendar.onReminder = { [weak self] meeting in
            self?.notch.sneak(Sneak(visual: .symbol("video.fill", tint: .accent),
                                    title: "\(meeting.title) in 5 min",
                                    detail: meeting.link.map { "Join \($0.provider.rawValue) · ⌃⌥J" },
                                    duration: 3, url: meeting.link?.url),
                              key: "meeting.\(meeting.id)", urgent: true)
        }
        calendar.start()
        meeting.nextEvent = { [weak calendar] in calendar?.next.map { ($0.title, $0.attendees) } }
        // Jamie syncs on its own while a login is saved, also a while after each call or meeting ends.
        meeting.jamie.meetingEnds = { [weak calendar] in calendar?.today.filter { $0.kind.takesAttention }.map(\.end) ?? [] }
        if !sample { meeting.jamie.startAutomatic() }
        let companion = MeetingCompanion(cast: cast)
        self.companion = companion
        companion.onOpenCard = { [weak self] id in
            if let url = URL(string: "\(Brand.urlScheme)://meeting?card=\(id)") { self?.showMeetingCard(url) }
        }
        meeting.onPopOut = { [weak self] in
            companion.open()
            self?.notch.collapse()
        }
        let pull = { [weak self] in
            companion.beginFollow()
            self?.notch.collapse()
        }
        agents.onFigurePull = pull
        meeting.onListening = { companion.listening = $0 }
        // MARK: Ask Tara (strand ask): ⌃⌥T (see applyAskTara) or a click on the floating Tara opens
        // a question bubble beside her; the answer comes from an agent.py of its own (on the demo
        // meetings with sample data or a preview).
        let ask = AskTara(demo: sample)
        self.ask = ask
        companion.ask = ask
        ask.wispr = dictation  // the mic dictates with Wispr Flow while it runs
        ask.notes = daily.notes  // "Save to notes" without a notes vault
        // Opening Ask Tara syncs an old Jamie sync in the background; new meetings reach her agent at once.
        ask.onOpen = { [weak meeting] in
            companion.showAsk()
            meeting?.jamie.syncIfDue(.askOpened)
        }
        meeting.onMemoryChanged = { [weak ask] in ask?.reloadMemory() }
        ask.onClose = { companion.hideAsk() }
        // Screenshots and previews never take the keyboard from the app the user types in.
        if options.capturable || preview { companion.takesKeyboard = false }
        if let name = options.preview, name.hasPrefix("ask-") { ask.preview(name) }
        meeting.onCard = { [weak self] entry in
            // Popped out, the bubble beside the character takes the sneak's place.
            if companion.isOpen {
                companion.show(entry)
                return
            }
            // A click on the line opens the panel at that card (handled in `application(_:open:)`).
            self?.notch.sneak(Sneak(visual: .symbol(MeetingStyle.symbol(entry.card.kind), tint: MeetingStyle.sneakTint(entry.card.kind)),
                                    title: entry.card.kind == .prep ? "Prep for \(entry.card.detail ?? "the meeting")" : entry.card.detail ?? entry.card.title,
                                    duration: 6,
                                    url: URL(string: "\(Brand.urlScheme)://meeting?card=\(entry.id)")),
                              key: "meeting.\(entry.id)", onlyAtRest: true, urgent: entry.card.kind == .contradiction)
        }

        wheel = WheelController(state: state, switcher: AppSwitcher())
        wheel.onTapNotch = { [weak self] in self?.notch.tapNotch() }
        wheel.onPullDown = pull
        wheel.canPull = { [weak self] in self?.notch.canPullFigure(at: $0) ?? false }
        // Strand polish: Tara squashes while the closed island is pressed (not the open panel's
        // figure) and pulls out of the music ear too.
        wheel.onPress = { [weak self] down in
            guard let self, self.notchModel.handlePressed != down else { return }
            guard !down || self.notchModel.interaction != .expanded else { return }
            self.notchModel.handlePressed = down
        }
        music.onFigurePull = pull
        wheel.onWillOpen = { [weak self] in self?.notch.wheelWillOpen() }
        wheel.onDidClose = { [weak self] in self?.notch.wheelDidClose() }
        wheel.onSelectModule = { [weak self] kind in self?.notch.show(kind) }
        wheel.currentModuleSlot = { [weak self] in
            guard let self else { return nil }
            return self.state.settings.position(of: self.notchModel.module)
        }
        wheel.startMonitoring()
        if options.capturable || preview {
            notch.allowCapture()
            wheel.allowCapture()
        }

        setup = SetupCenter(state: state)
        if preview {
            setup.usePreviewLedger()
        } else if !options.sampleData && !options.tour {
            setup.checkClaudePlugin()
        }
        settingsWindow = SettingsWindowController(state: state, cast: cast, setup: setup, jamie: meeting.jamie) { [weak self] in
            self?.showSetup(at: .agents)
        }
        statusItem = StatusItemController(
            state: state,
            onToggleNotch: { [weak self] in self?.notch.toggleFromKeyboard() },
            onOpenWheel: { [weak self] in self?.wheel.openFromShortcut() },
            onOpenSettings: { [weak self] in self?.settingsWindow.show() }
        )
        statusItem.keepingAwake = { [weak self] in self?.keepAwake.isOn ?? false }
        statusItem.onToggleKeepAwake = { [weak self] in self?.keepAwake.toggle() }
        statusItem.onOpenSetup = { [weak self] in self?.showSetup(at: .agents) }
        statusItem.updater = updater
        hotKey = HotKey.controlOptionSpace { [weak self] in self?.notch.toggleFromKeyboard() }
        joinHotKey = HotKey.controlOptionJ { [weak self] in self?.joinNextMeeting() }
        // Quiet by default, silent while watching.
        notchModel.earsMode = state.settings.earsMode
        agents.setDisabledProviders(Set(state.settings.disabledProviders))
        state.onProvidersChanged = { [weak self] ids in self?.agents.setDisabledProviders(ids) }
        state.onEarsModeChanged = { [weak self] mode in
            withAnimation(.easeInOut(duration: 0.2)) { self?.notchModel.earsMode = mode }
        }
        watchMode.automatic = { [weak self] in (self?.state.settings.watchAutomatic ?? true) && !preview }
        watchMode.timer = { [weak self] in self?.state.settings.watchTimer ?? .twoHours }
        watchMode.onChange = { [weak self] on in self?.notch.setWatching(on) }
        watchMode.screen = { [weak self] in self?.notch.islandScreen }
        notchModel.toggleWatch = { [weak self] in self?.watchMode.toggle() }
        watchHotKey = HotKey.controlOptionW { [weak self] in self?.watchMode.toggle() }
        statusItem.watching = { [weak self] in self?.watchMode.isOn ?? false }
        statusItem.onToggleWatch = { [weak self] in self?.watchMode.toggle() }
        watchMode.start()
        state.onLocalAPIToggle = { [weak self] on in self?.setLocalAPI(on) }
        if options.preview == nil { setLocalAPI(state.settings.localAPIEnabled) }

        // First launch: onboarding. Nothing is set up before the user's click there.
        if (!state.settings.didOnboard && !preview && !options.tour) || options.onboarding {
            showSetup(at: options.onboardingStep.flatMap(Onboarding.Step.init(rawValue:)))
            state.settings.didShowAccessibilityIntro = true
        }
        // Explain the Accessibility permission once, on first launch.
        let showIntro = !state.settings.didShowAccessibilityIntro && !state.isAccessibilityTrusted && !options.tour
        if showIntro { state.settings.didShowAccessibilityIntro = true }
        if options.openSlotPicker { SlotRowDemo.open(.bottom) }
        if options.openProjectPicker { SlotRowDemo.openProject(AvatarCast.homeProject) }
        if showIntro || options.openSettings || options.openSlotPicker || options.openProjectPicker {
            settingsWindow.show()
        }

        if options.openWheel {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                self?.wheel.openFromShortcut()
            }
        }
        if options.expand == "loops" {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                agents.showsLoops = true
                self?.notch.expand(.agents, pinned: true)
            }
        } else if options.expand == "peek" {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                self?.notch.tourPeek()
            }
        } else if let name = options.expand, let kind = ModuleKind(rawValue: name) {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                self?.notch.expand(kind, pinned: true)
            }
        }
        if options.demoFinished {
            // The finished moment on the main session, for screenshots.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(900))
                if let id = self?.agents.main?.id { self?.agents.markFinished(id) }
            }
        }
        if options.demoSneak {
            Task { [weak self] in
                // Wait for the first scan to find a session.
                for _ in 0..<40 where self?.agents.main == nil { try? await Task.sleep(for: .milliseconds(250)) }
                try? await Task.sleep(for: .seconds(0.8))
                self?.demoAgentFinished()
            }
        }
        startDaily(tools: tools, sample: sample)
        // MARK: Command palette and agents inbox (strand cmdk)
        // ⌃⌥K (and ⌘K while open) searches every module that is a `PaletteProvider`; ⌃⌥A works
        // through prompts, questions, finished turns and failed loops, with its count in the ear.
        let agentsInbox = AgentsInbox(approvals: approvals, agents: agents)
        notchModel.inbox = agentsInbox
        agents.inbox = agentsInbox
        notch.paletteSources.persists = state.persists
        notch.paletteSources.providers = [ClosurePaletteProvider { [weak self] _ in
            guard let self else { return [] }
            let setup: [(Onboarding.Step, String)] = [(.agents, "Set up your agents"), (.meetings, "Set up meetings and Tara's brain"),
                                                      (.tools, "Choose tools"), (.tara, "Choose Tara's look")]
            return [PaletteItem(id: "settings", title: Localization.string("Settings"), symbol: "gearshape", kind: .settings,
                                keywords: ["preferences", "display", "quiet", "providers", "loops"],
                                perform: { [weak self] in self?.settingsWindow.show() })]
                + setup.map { step, title in
                    PaletteItem(id: "setup:\(step.rawValue)", title: Localization.string(title), subtitle: Localization.string("Setup"),
                                symbol: "sparkles", kind: .settings, keywords: ["onboarding", "setup"],
                                perform: { [weak self] in self?.showSetup(at: step) })
                }
        }]
        // `paletteSources.askTara` is set in applyAskTara while the Ask Tara tool is on.
        // The palette is core, like the island it opens from: ⌃⌥K always. ⌃⌥A follows the
        // Agents tab (applyTools).
        paletteHotKey = HotKey.controlOptionK { [weak self] in self?.notch.togglePalette() }
        // MARK: end of strand cmdk

        applyTools()
        notch.inbox.loadPeople(from: people)
        music.onTrackChange = { [weak self, weak music] track in
            guard music?.musicOn == true else { return }  // media strand: Music off, no cover sneak
            self?.notch.sneak(Sneak(visual: .cover(track.cover), title: track.title, detail: track.artist),
                              key: "music", onlyAtRest: true, counts: false)
        }
        agents.onLoopFinished = { [weak self] loop in self?.loopFinished(loop) }
        if let name = options.preview, let agendaPreview {
            agendaPreview.run(name, notch: notch, agents: agents)
        } else if options.preview?.hasPrefix("notes-settings") == true {
            NotesSettingsPreview.show(state: state)   // Notes (vault strand)
        } else if let name = options.preview, name == "setup-consent" || name == "setup-done" || name == "setup-agents" || name.hasPrefix("onboarding") {
            // The setup pages with nothing behind them (the center is in preview mode).
            agents.usePreview(PreviewDirector.snapshot(agentsActive: false))
            if name == "setup-done" {
                SetupLedgerWindow.show(center: setup)
            } else {
                setup.previewMoreAgents = name == "setup-agents"  // strand agents: all six tools found
                setup.resetForPreview()
                showOnboardingPreview(name)
            }
        } else if let name = options.preview {
            previewDirector = PreviewDirector(notch: notch, agents: agents, music: music)
            previewDirector?.system = system
            previewDirector?.run(name)
        } else if options.sampleData {
            previewDirector = PreviewDirector(notch: notch, agents: agents, music: music)
            previewDirector?.system = system
            previewDirector?.runSampleMode()
        } else {
            agents.startStatus()
            music.startLive()
            system.start()
            startExtras(system)
            startTools(tools)
        }
        if options.tour {
            Task { [weak self] in await self?.playTour() }
        }
        Log.app.info("Started (accessibility: \(self.state.isAccessibilityTrusted ? "yes" : "no", privacy: .public))")
    }

    /// The modules to show: available on this Mac and not switched off (all of them with
    /// sample data). At least one stays, so the island always has something to open.
    private func shownModules(sample: Bool) -> [NotchModule] {
        let available = sample ? allModules : allModules.filter { ModuleAvailability.isShown($0.kind, settings: state.settings) }
        let order = ModuleOrder.sorted(available.map(\.kind), by: state.settings.moduleOrder)
        let shown = order.compactMap { kind in available.first { $0.kind == kind } }
        return shown.isEmpty ? allModules.filter { $0.kind == .calendar } : shown
    }

    /// Quitting while Wispr Flow dictates into Ask Tara: its paste lands in the bubble first, not in
    /// the app behind it (Wispr Flow can't cancel, only stop and paste).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let ask, ask.isDictating else { return .terminateNow }
        ask.finishDictation { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        lidAwake?.quit()
        approvals?.stop()
        meeting?.shutdown()
        ask?.shutdown()
    }

    /// Reopening the app from Finder or Spotlight shows the settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow.show()
        return false
    }

    /// The same moments a person sees, driven without touching the pointer: an agent finishes,
    /// a meeting reminder, swipes through the modules, a status from the local API (posted by
    /// the recording script from outside), then the new slot picker. Quits at the end.
    private func playTour() async {
        func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        for _ in 0..<40 where agents.main == nil { await pause(0.25) }
        await pause(1.2)
        demoAgentFinished()                          // sneak: agent done
        await pause(3.2)
        calendar.demoReminder()                      // sneak: meeting in 5 min
        await pause(3.4)
        notch.perform(.down)                         // swipe down: open
        await pause(1.6)
        notch.perform(.right)                        // swipe right: Today
        await pause(1.4)
        notch.perform(.right)                        // swipe right: Next, countdown and Join
        await pause(2.2)
        notch.perform(.up)                           // swipe up: close
        await pause(0.8)
        await postStatusViaAPI()                     // a status through the local HTTP API
        await pause(3.4)
        SlotRowDemo.open(.bottom)
        settingsWindow.showForTour()
        await pause(4.0)
        NSApp.terminate(nil)
    }

    // MARK: Local API

    /// Battery, keep awake and long terminal commands, with their lines in the notch.
    private func startExtras(_ system: SystemModule) {
        battery.onChange = { [weak self, weak system] before, now in
            system?.battery = now
            self?.lidAwake?.check()
            guard let self, let now, let before else { return }
            if now.pluggedIn != before.pluggedIn {
                self.notch.sneak(Sneak(visual: .symbol(now.pluggedIn ? "bolt.fill" : "battery.75percent", tint: now.pluggedIn ? .ok : .neutral),
                                       title: now.pluggedIn ? (now.charging ? "Charging" : "On power") : "On battery",
                                       detail: "\(now.percent) %", duration: 2.4),
                                 key: "battery")
            } else if now.isLow && !before.isLow {
                self.notch.sneak(Sneak(visual: .symbol("battery.25percent", tint: .waiting), title: "Battery low", detail: "\(now.percent) %", duration: 3.4),
                                 key: "battery")
            }
        }
        battery.start()
        system.battery = battery.state
        keepAwake.onChange = { [weak self, weak system] on in
            system?.keepAwake = on
            // The lid level rests on keep awake: off together.
            if !on { self?.lidAwake?.switchOff() }
        }
        system.onToggleKeepAwake = { [weak self] in self?.keepAwake.toggle() }
        system.onDarkModeDenied = { [weak self] in
            self?.notch.sneak(Sneak(visual: .symbol("moon", tint: .waiting),
                                    title: Localization.string("Dark mode needs permission to control System Events"),
                                    detail: Localization.string("System Settings › Privacy & Security › Automation"), duration: 4.4),
                              key: "dark-mode")
        }
        startLidAwake(system)
        let shell = ShellMonitor(folder: setup.paths.shellActivity)
        shell.onChange = { [weak system] running in system?.longCommands = running }
        shell.onFinished = { [weak self] done in
            self?.notch.sneak(Sneak(visual: .symbol(done.succeeded ? "checkmark.circle" : "xmark.circle", tint: done.succeeded ? .ok : .critical),
                                    title: done.command, detail: ShellActivity.line(done).replacingOccurrences(of: "finished · ", with: ""), duration: 3.4),
                              key: "shell.\(done.end.timeIntervalSince1970)")
        }
        shell.start()
        self.shell = shell
    }

    /// Keep awake with the lid closed: the switch in the System tab, the ear while on, a line
    /// when it ends by itself. Sleep left off by a crash comes back first.
    private func startLidAwake(_ system: SystemModule) {
        let lid = LidAwakeController(marker: setup.paths.lidAwakeMarker)
        lidAwake = lid
        setup.lidAwake = lid
        lid.cleanUpAfterLaunch()
        lid.installRule = { [weak self] in await self?.setup.installLidRule() ?? .cancelled }
        lid.onChange = { [weak system] state, busy in
            withAnimation(Theme.snappy) {
                system?.lidAwake = state
                system?.lidBusy = busy
            }
        }
        lid.onNotice = { [weak self, weak system] notice in
            let title: String
            var detail: String?
            switch notice {
            case .ended(let reason):
                title = "The Mac sleeps again with the lid closed"
                detail = reason == .batteryLow ? "Battery at the floor" : reason == .tooHot ? "Too hot" : "Time is up"
                // A safety stop, or a closed lid, also ends keep awake: its assertion would keep
                // the Mac awake on its own.
                if reason != .timeUp || LidAwakeController.closedLidSleeps() { self?.keepAwake.set(false) }
            case .refused(let reason):
                title = reason == .tooHot ? "Too hot to stay awake with the lid closed" : "Battery too low to stay awake with the lid closed"
                detail = reason == .tooHot ? "Let the Mac cool down first"
                    : system?.lidFloor == LidAwake.floors.first ? "Plug in" : "Plug in, or pick a lower floor"
            case .alreadyOff: title = "Sleep was already switched off elsewhere"
            case .failed: title = "Couldn't keep the Mac awake with the lid closed"
            case .stillOff:
                title = "Couldn't let the Mac sleep again with the lid closed"
                detail = "Trying again in a minute"
            case .ruleFailed: title = "Couldn't set up keeping awake with the lid closed"
            }
            self?.notch.sneak(Sneak(visual: .symbol("laptopcomputer", tint: notice.isEnd ? .neutral : .waiting),
                                    title: Localization.string(title), detail: detail.map(Localization.string), duration: 3.4),
                              key: "lid-awake")
        }
        system.lidNeedsPassword = { [weak self] in self?.setup.isSetUp(.lidAwake) != true }
        system.onLidAwake = { [weak self, weak system] limit in
            guard let self else { return }
            if let limit {
                self.keepAwake.set(true)
                self.lidAwake?.switchOn(limit, floor: system?.lidFloor ?? LidAwake.defaultFloor)
            } else {
                self.lidAwake?.switchOff()
            }
        }
    }

    /// The clipboard watcher (only while the module is on) and a line when a focus or break ends.
    private func startTools(_ tools: ToolsModule) {
        tools.isEnabled = { [weak self] in
            guard let self else { return false }
            return ToolSwitches.isOn(.clipboard, in: self.state.settings)
        }
        tools.onPhaseEnd = { [weak self, weak tools] ended, next in
            let focusDone = ended == .focus
            self?.notch.sneak(Sneak(visual: .symbol(focusDone ? "cup.and.saucer.fill" : "timer", tint: focusDone ? .ok : .accent),
                                    title: focusDone ? "Focus done" : "Back to focus",
                                    detail: "\(next.title), \(Int((tools?.timer.length(of: next) ?? 0) / 60)) min",
                                    duration: 3.4),
                              key: "focus", urgent: true)
        }
        tools.start()
        toolsLive = true
        applyTools()
        headphones.onBattery = { [weak self] battery in
            let low = (battery.lowest ?? 100) <= 20
            self?.notch.sneak(Sneak(visual: .symbol(battery.left != nil ? "airpodspro" : "headphones", tint: low ? .waiting : .ok),
                                    title: battery.name, detail: battery.line, duration: 3.6),
                              key: "headphones")
        }
        headphones.start()
        tools.onCountdownDone = { [weak self] length in
            NSSound(named: "Glass")?.play()
            self?.notch.sneak(Sneak(visual: .symbol("hourglass", tint: .waiting), title: "Time's up",
                                    detail: "\(Int(length / 60)) min timer", duration: 4),
                              key: "countdown", urgent: true)
        }
    }

    /// The tools switched on in Settings › Tools, applied to what sits outside the tabs: the plus
    /// button and its shortcuts, the clipboard shortcut and watcher, the shelf, keep awake.
    private func applyTools() {
        let settings = state.settings
        // Previews and sample data show every tool.
        let sample = options.preview != nil || options.sampleData
        let isOn = { (feature: ToolFeature) in sample || ToolSwitches.isOn(feature, in: settings) }
        let capture = isOn(.quickCapture)
        notchModel.requestCapture = capture ? { [weak self] in self?.notch.openCapture() } : nil
        captureHotKey = capture ? captureHotKey ?? HotKey.controlOptionN { [weak self] in self?.notch.openCapture() } : nil
        inboxHotKey = capture ? inboxHotKey ?? HotKey.controlOptionI { if let file = CaptureInbox.markdownFile { CaptureInbox.openMarkdown(file) } } : nil

        // Agents inbox (strand cmdk): ⌃⌥A only while the Agents tab is shown.
        let agentsShown = notchModel.modules.contains { $0.kind == .agents }
        agentsInboxHotKey = agentsShown ? agentsInboxHotKey ?? HotKey.controlOptionA { [weak self] in self?.notch.toggleInbox() } : nil
        // end of strand cmdk
        applyAskTara(isOn(.askTara))

        let awake = isOn(.keepAwake)
        system?.offersKeepAwake = awake
        if !awake { keepAwake.set(false) }

        // Media strand: Music itself (its helper and clock stop when off), synced lyrics, the lyric
        // line on hover and volume per app, inside Music.
        if let music = allModules.lazy.compactMap({ $0 as? NowPlayingModule }).first {
            music.musicOn = sample || ModuleAvailability.isShown(.nowPlaying, settings: settings)
            music.lyricsOn = isOn(.lyrics)
            music.lyricsOnHover = isOn(.lyricsOnHover)
            music.mixerOn = isOn(.appVolume) && AppVolumeMixer.isSupported
        }

        guard let tools else { return }
        daily.apply(on: Set(ToolFeature.allCases.filter(isOn)))
        let tabs: [(ToolsModule.Tab, ToolFeature)] = [(.clipboard, .clipboard), (.timer, .timers), (.shelf, .shelf), (.notes, .notes)]
        tools.tabs = tabs.filter { isOn($0.1) }.map(\.0)
        tools.converts = isOn(.imageConverter)
        guard toolsLive else { return }
        let clipboard = tools.tabs.contains(.clipboard)
        clipboardHotKey = clipboard ? clipboardHotKey ?? HotKey.controlOptionV { [weak self, weak tools] in
            tools?.tab = .clipboard
            self?.notch.expand(.tools, pinned: true)
        } : nil
        // Files dragged onto the notch open the shelf, while there is one.
        notch.onFileDrag = tools.tabs.contains(.shelf) ? { [weak tools] in tools?.tab = .shelf } : nil
    }

    /// Onboarding: first launch, "Set up…" in the menu, and "Set up more…" in Settings.
    func showSetup(at step: Onboarding.Step? = nil) {
        if onboarding == nil {
            let window = OnboardingWindowController(model: Onboarding(state: state, cast: cast, setup: setup,
                                                                      jamie: meeting?.jamie ?? JamieConnect()))
            window.onClose = { [weak self] in self?.state.settings.didOnboard = true }
            onboarding = window
        }
        onboarding?.show(at: step)
    }

    /// `--preview onboarding[:step[:jamie]]`: a step with nothing behind it; the Jamie row in
    /// one of its states (`connecting`, `login`, `syncing`, `done`, `empty`, `failed`).
    private func showOnboardingPreview(_ name: String) {
        let parts = name.split(separator: ":").map(String.init)
        let step = name == "setup-consent" || name == "setup-agents" ? .agents : parts.count > 1 ? Int(parts[1]).flatMap(Onboarding.Step.init(rawValue:)) : nil
        showSetup(at: step)
        guard parts.count > 2, let jamie = onboarding?.model.jamie else { return }
        switch parts[2] {
        case "connecting": jamie.preview(.connecting)
        case "login": jamie.preview(.login(nil))
        case "syncing": jamie.preview(.syncing(count: 7, title: "Weekly with Lena"))
        case "done": jamie.preview(.done(meetings: 42, hint: nil))
        case "empty": jamie.preview(.done(meetings: 0, hint: "empty_account"))
        case "failed": jamie.preview(.failed("Jamie login failed: access_denied"))
        default: break
        }
    }

    private func setLocalAPI(_ on: Bool) {
        api?.stop()
        api = nil
        guard on, let token = APIToken.load() else { return }
        let server = LocalAPIServer(token: token) { [weak self] status in
            Task { @MainActor in self?.show(status) }
        }
        server.start()
        api = server
    }

    /// `<scheme>://status?title=…&detail=…&tint=ok` (`Brand.urlScheme`)
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == Brand.urlScheme {
            if url.host == "oauth" {
                daily.handleOAuth(url)
                continue
            }
            if url.host == "meeting" {
                showMeetingCard(url)
                continue
            }
            guard url.host == "status", let status = try? StatusPayload.make(url: url) else {
                Log.app.error("Ignored status link without a title")
                continue
            }
            show(status)
        }
    }

    /// `<scheme>://meeting?card=3`: the Meeting panel, scrolled to that card.
    private func showMeetingCard(_ url: URL) {
        let card = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "card" }?.value.flatMap(Int.init)
        meeting?.focused = card
        notch.expand(.meeting, pinned: true)
    }

    /// A loop finished: one line with its silver face, a click opens what it delivered.
    private func loopFinished(_ loop: AgentSnapshot.LoopStatus) {
        let failed = loop.last?.status == .fail
        let log = Runtime.jobs?.logURL
        notch.sneak(Sneak(visual: .symbol(failed ? "xmark" : "checkmark", tint: failed ? .critical : .ok),
                          title: "\(loop.displayName) \(failed ? "failed" : "done")",
                          detail: failed ? (log != nil ? "Open the log" : loop.last?.note) : (loop.outboxLink != nil ? "Open result" : loop.last?.note),
                          duration: 3, url: failed ? log : loop.outboxLink),
                    key: "loop.\(loop.name)")
    }

    /// A posted status as a sneak peek; with `loop`, it updates that loop too.
    private func show(_ status: StatusPayload) {
        if let loop = status.loop, let state = status.state {
            agents.applyPush(loop: loop, state: state)
            if state == "ok" || state == "fail" { return }  // the finished sneak covers it
        }
        let symbol = status.icon.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil ? $0 : nil }
            ?? "bell.fill"
        let tint = Sneak.SneakTint(rawValue: status.tint.rawValue) ?? .accent
        notch.sneak(Sneak(visual: .symbol(symbol, tint: tint), title: status.title, detail: status.detail,
                          duration: status.seconds, url: status.url),
                    key: "api.\(status.key ?? UUID().uuidString)")
    }

    /// Recordings: the same request scripts/notch-status.sh sends, to our own endpoint.
    private func postStatusViaAPI() async {
        guard let token = APIToken.load(), let url = URL(string: "http://127.0.0.1:\(LocalAPIServer.port)/status") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"title":"Digest ready","detail":"5 sources","tint":"ok","icon":"newspaper.fill"}"#.utf8)
        _ = try? await URLSession.shared.data(for: request)
    }

    /// ⌃⌥J: join the next meeting, or say why not.
    private func joinNextMeeting() {
        if calendar.nextAttention?.link != nil {
            calendar.join()
        } else {
            notch.sneak(Sneak(visual: .symbol("video.slash", tint: .neutral),
                              title: calendar.nextAttention == nil ? "No meeting coming up" : "No call link in \(calendar.nextAttention!.title)"),
                        key: "meeting.join")
        }
    }

    /// The sneak an agent posts when it finishes, on the most recent session.
    private func demoAgentFinished() {
        guard let agent = agents.main else { return }
        agents.markFinished(agent.id)
        agents.onFinished?(agent)
    }

    /// Ask Tara (strand ask): ⌃⌥T and the click on the floating Tara while the tool is on; off, an
    /// open question bubble closes.
    private func applyAskTara(_ on: Bool) {
        guard let ask else { return }
        askHotKey = on ? askHotKey ?? HotKey.controlOptionT(action: { [weak ask] in ask?.hotKeyPressed() },
                                                            release: { [weak ask] in ask?.hotKeyReleased() }) : nil
        companion?.onTapFigure = on ? { [weak ask] in ask?.toggle() } : nil
        companion?.onDrop = on ? { [weak ask] point in ask?.droppedOnWindow(at: point) } : nil
        // The palette's Ask Tara rows: open her, or ask straight away what was typed.
        notch.paletteSources.askTara = on ? { [weak ask] query in
            guard let ask else { return }
            ask.open()
            if !query.isEmpty {
                ask.text = query
                ask.send()
            }
        } : nil
        if !on { ask.close() }
    }

    private func applyDemoSlots() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.calculator") else { return }
        state.settings[.bottom] = SlotApp(bundleID: "com.apple.calculator", name: "Calculator", path: url.path)
    }
}

// MARK: Daily tools (strand daily)

extension AppDelegate {
    /// Weather and day progress in the calendar's header and the ears, notes in the Tools tab,
    /// last night's scores as a morning line. Previews and sample data use made-up values and
    /// never touch the network, the Keychain or the location.
    fileprivate func startDaily(tools: ToolsModule, sample: Bool) {
        tools.notes = daily.notes
        let ears = DailyEars(store: daily)
        notchModel.restEars = { ears.shown }
        if sample {
            DailyPreview.prepare(options.preview, store: daily)
        }
        // Dropped while the panel is open or in Watch mode (and not counted there): it comes again.
        daily.onMorningLine = { [weak self] health, weather in
            let level = health.headline.map { HealthDay.level($0, source: health.source) } ?? .good
            return self?.notch.sneak(Sneak(visual: .symbol("heart.fill", tint: level == .good ? .ok : level == .fair ? .waiting : .critical),
                                           title: DailyText.health(health), detail: weather.map { WeatherReport.degrees($0.temperature) }, duration: 5),
                                     key: "daily.morning", onlyAtRest: true, counts: false) ?? false
        }
        if options.preview == "daily-settings" {
            // Settings › Daily with every daily tool on (in memory only: previews don't save).
            for feature in [ToolFeature.weather, .dayProgress, .notes, .health] { ToolSwitches.set(feature, on: true, in: &state.settings) }
            DailyPreview.showSettings(state: state)
        }
        if let name = options.preview, DailyPreview.handles(name) {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(900))
                guard let self else { return }
                DailyPreview.run(name, store: self.daily, notch: self.notch, tools: tools, agents: self.agents)
            }
        }
    }
}
