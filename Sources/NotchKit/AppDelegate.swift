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
    private var watchHotKey: HotKey?
    private let watchMode = WatchMode()
    private var previewDirector: PreviewDirector?
    private var agendaPreview: AgendaPreview?
    private var setup: SetupCenter!
    private var setupWindow: SetupWindowController?
    /// Every module built, shown or not; `NotchModel.modules` holds the shown ones.
    private var allModules: [NotchModule] = []
    private var system: SystemModule?
    private let battery = BatteryMonitor()
    private let keepAwake = KeepAwake()
    private var shell: ShellMonitor?
    private let updater = Updater()
    private var approvals: ApprovalCenter?

    func applicationDidFinishLaunching(_ notification: Notification) {
        state = AppState()
        if options.demoSlots { applyDemoSlots() }

        let cast = AvatarCast(state: state)
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
        let agendaPreview: AgendaPreview? = AgendaPreview.handles(options.preview) ? AgendaPreview() : nil
        self.agendaPreview = agendaPreview
        let people: (any PeopleProvider)? = samples ?? Runtime.people
        let agenda = agendaPreview?.agenda ?? AgendaModule(variant: .b, people: people, source: sample ? nil : calendar)
        // Today: the connector's list, Apple Reminders when switched on, or both.
        let reminders = RemindersSource()
        reminders.base = Runtime.today
        reminders.enabled = { [weak self] in self?.state.settings.remindersInToday ?? false }
        let todayProvider: (any TodayProvider)? = samples ?? reminders
        let today = agendaPreview?.today ?? todayProvider.map { TodayModule(provider: $0, agenda: agenda) }
        let system = SystemModule()
        self.system = system
        allModules = [agents, agenda, music, system, dictation]
        if let today { allModules.insert(today, at: 1) }
        notchModel = NotchModel(modules: shownModules(sample: sample))
        // --preview: mock data for screenshots and recordings; the features themselves are live.
        notchModel.previewFeatures = preview
        agents.music = music
        notchModel.cast = cast
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
        approvals.onEmpty = { [weak self] in self?.notch.collapse() }
        approvals.onChange = { [weak agents] requests in agents?.setPendingApprovals(requests) }
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

        wheel = WheelController(state: state, switcher: AppSwitcher())
        wheel.onTapNotch = { [weak self] in self?.notch.tapNotch() }
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
        if preview { setup.usePreviewLedger() }
        settingsWindow = SettingsWindowController(state: state, cast: cast, setup: setup) { [weak self] in self?.showSetup() }
        statusItem = StatusItemController(
            state: state,
            onToggleNotch: { [weak self] in self?.notch.toggleFromKeyboard() },
            onOpenWheel: { [weak self] in self?.wheel.openFromShortcut() },
            onOpenSettings: { [weak self] in self?.settingsWindow.show() }
        )
        statusItem.keepingAwake = { [weak self] in self?.keepAwake.isOn ?? false }
        statusItem.onToggleKeepAwake = { [weak self] in self?.keepAwake.toggle() }
        statusItem.onOpenSetup = { [weak self] in self?.showSetup() }
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
        notchModel.toggleWatch = { [weak self] in self?.watchMode.toggle() }
        watchHotKey = HotKey.controlOptionW { [weak self] in self?.watchMode.toggle() }
        statusItem.watching = { [weak self] in self?.watchMode.isOn ?? false }
        statusItem.onToggleWatch = { [weak self] in self?.watchMode.toggle() }
        watchMode.start()
        state.onLocalAPIToggle = { [weak self] on in self?.setLocalAPI(on) }
        if options.preview == nil { setLocalAPI(state.settings.localAPIEnabled) }

        // First launch: the setup page. Nothing is set up before the user's click there.
        if !state.settings.didOnboard && !preview && !options.tour {
            showSetup()
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
        notchModel.requestCapture = { [weak self] in self?.notch.openCapture() }
        captureHotKey = HotKey.controlOptionN { [weak self] in self?.notch.openCapture() }
        notch.inbox.loadPeople(from: people)
        music.onTrackChange = { [weak self] track in
            self?.notch.sneak(Sneak(visual: .cover(track.cover), title: track.title, detail: track.artist),
                              key: "music", onlyAtRest: true, counts: false)
        }
        agents.onLoopFinished = { [weak self] loop in self?.loopFinished(loop) }
        if let name = options.preview, let agendaPreview {
            agendaPreview.run(name, notch: notch, agents: agents)
        } else if let name = options.preview, name == "setup-consent" || name == "setup-done" {
            // The setup pages with nothing behind them (the center is in preview mode).
            agents.usePreview(PreviewDirector.snapshot(agentsActive: false))
            if name == "setup-consent" {
                setup.resetForPreview()
                showSetup()
            } else {
                SetupLedgerWindow.show(center: setup)
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
        }
        if options.tour {
            Task { [weak self] in await self?.playTour() }
        }
        Log.app.info("Started (accessibility: \(self.state.isAccessibilityTrusted ? "yes" : "no", privacy: .public))")
    }

    /// The modules to show: available on this Mac and not switched off (all of them with
    /// sample data). At least one stays, so the island always has something to open.
    private func shownModules(sample: Bool) -> [NotchModule] {
        let shown = sample ? allModules : allModules.filter { ModuleAvailability.isShown($0.kind, settings: state.settings) }
        return shown.isEmpty ? allModules.filter { $0.kind == .calendar } : shown
    }

    func applicationWillTerminate(_ notification: Notification) {
        approvals?.stop()
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
        keepAwake.onChange = { [weak system] on in system?.keepAwake = on }
        system.onToggleKeepAwake = { [weak self] in self?.keepAwake.toggle() }
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

    /// The consent page: what this Mac has and what can be set up, one click for all of it.
    func showSetup() {
        if setupWindow == nil {
            let window = SetupWindowController(center: setup)
            window.onClose = { [weak self] in self?.state.settings.didOnboard = true }
            setupWindow = window
        }
        setupWindow?.show()
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
            guard url.host == "status", let status = try? StatusPayload.make(url: url) else {
                Log.app.error("Ignored status link without a title")
                continue
            }
            show(status)
        }
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

    private func applyDemoSlots() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.calculator") else { return }
        state.settings[.bottom] = SlotApp(bundleID: "com.apple.calculator", name: "Calculator", path: url.path)
    }
}
