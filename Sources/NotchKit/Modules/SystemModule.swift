import AppKit
import NotchCore
import Observation
import SwiftUI

/// Is the Mac overloaded, and by what? CPU, GPU, memory and network with a two-minute history,
/// and the apps behind them (helpers summed into their app). Samples every 2 s while the panel is
/// open, every 10 s otherwise (CPU and memory only, for the warning). Nothing is ever quit from
/// here. Below: keep awake, dark mode and the desktop icons as quick switches.
@MainActor
@Observable
final class SystemModule: NotchModule {
    let kind = ModuleKind.system
    let symbol = ModuleSymbols.symbol(.system)

    private(set) var cpu = 0.0
    private(set) var gpu: Double?
    private(set) var memory: MemoryStats?
    private(set) var cpuHistory: [Double] = []
    private(set) var gpuHistory: [Double] = []
    private(set) var memoryHistory: [Double] = []
    /// Bytes per second over Wi-Fi and Ethernet; nil until two readings exist.
    private(set) var networkDown: Double?
    private(set) var networkUp: Double?
    private(set) var networkHistory: [Double] = []
    private(set) var apps: [AppUsage] = []
    private(set) var thermal = ProcessInfo.processInfo.thermalState
    private(set) var alertLevel = SystemAlert.Level.none
    /// Battery and charging (nil on a Mac without one).
    var battery: BatteryState?
    /// Camera or microphone in use right now, and by which app.
    private(set) var media = MediaUse()
    /// The main character, who listens in the ear while the camera or microphone is in use.
    @ObservationIgnored var cast: AvatarCast?
    /// "Keep awake" holds the display on.
    var keepAwake = false
    /// Keep awake is switched on in Settings › Tools.
    var offersKeepAwake = true
    /// Tara's memory is paused (the switch in this row pauses it until resumed, or resumes it).
    var memoryPaused = false
    @ObservationIgnored var onToggleMemory: (() -> Void)?
    @ObservationIgnored var onToggleKeepAwake: (() -> Void)?
    /// Keep awake's second level on a laptop: also with the lid closed, until a time or until
    /// switched off. `lidBusy` while macOS asks for the password or pmset runs.
    var lidAwake = LidAwake.State.off
    var lidBusy = false
    /// The charge it stops at on battery, picked beside the times (remembered).
    var lidFloor = UserDefaults.standard.object(forKey: "lidAwake.floor") as? Int ?? LidAwake.defaultFloor {
        didSet { UserDefaults.standard.set(lidFloor, forKey: "lidAwake.floor") }
    }
    /// The time choice is open in the switches row (closes with the panel).
    var lidPickerOpen = false
    /// A time switches it on (or moves the end), nil switches it off.
    @ObservationIgnored var onLidAwake: ((LidAwakeLimit?) -> Void)?
    /// The rule isn't installed yet: the first switch asks for the password.
    @ObservationIgnored var lidNeedsPassword: () -> Bool = { true }
    /// The Mac's appearance and Finder's desktop icons, read again whenever the panel opens.
    private(set) var darkMode = false
    private(set) var desktopHidden = false
    /// Terminal commands running for 30 s or more (from the shell snippet).
    var longCommands: [ShellActivity.Running] = []
    @ObservationIgnored private var mediaTask: Task<Void, Never>?
    var sort = ProcessGrouping.Sort.cpu {
        didSet { if sort != oldValue { regroup() } }
    }

    /// The dark mode switch flipped back: System Events may not be controlled (Automation).
    @ObservationIgnored var onDarkModeDenied: (() -> Void)?

    /// One sneak per overload episode ("Memory tight · Google Chrome 3.1 GB").
    @ObservationIgnored var onAlert: ((String, String?, SystemAlert.Level) -> Void)?

    @ObservationIgnored private let sampler = SystemSampler()
    @ObservationIgnored private let queue = DispatchQueue(label: Brand.identifier + ".system", qos: .utility)
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var expanded = false
    @ObservationIgnored private var alert = SystemAlert()
    @ObservationIgnored private var processes: [ProcessSample] = []
    @ObservationIgnored private var lastNetwork: (totals: NetworkTotals, date: Date)?
    @ObservationIgnored private var previewMode = false
    /// Two minutes at 2 s.
    static let historyLength = 60

    func start() {
        if mediaTask == nil, !previewMode {
            // The camera and microphone light: a cheap check every 3 s.
            mediaTask = Task { [weak self] in
                while !Task.isCancelled {
                    let next = MediaUse.read()
                    if let self, next != self.media { withAnimation(.easeInOut(duration: 0.2)) { self.media = next } }
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sample()
                try? await Task.sleep(for: .seconds(self.expanded ? 2 : 10))
            }
        }
    }

    /// Previews: fixed values.
    func usePreview(cpu: [Double], gpu: [Double], memory: MemoryStats, apps: [AppUsage],
                    network: [Double] = [], upload: Double? = nil) {
        previewMode = true
        task?.cancel()
        task = nil
        cpuHistory = cpu
        gpuHistory = gpu
        self.cpu = cpu.last ?? 0
        self.gpu = gpu.last
        self.memory = memory
        memoryHistory = Array(repeating: memory.fraction, count: Self.historyLength)
        networkHistory = network
        networkDown = network.last
        networkUp = upload
        self.apps = apps
        alertLevel = memory.pressure == .critical ? .critical : memory.pressure == .warn ? .warn : .none
    }

    /// Previews: keep awake with the lid closed in a given state.
    func usePreviewLid(_ state: LidAwake.State, picker: Bool = false) {
        previewMode = true
        lidAwake = state
        lidPickerOpen = picker
    }

    /// Previews: the camera in use by an app.
    func usePreviewMedia(_ use: MediaUse) {
        previewMode = true
        mediaTask?.cancel()
        media = use
    }

    private func sample() async {
        let detailed = expanded
        let sampler = self.sampler
        let reading = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: sampler.read(processes: detailed)) }
        }
        cpu = reading.cpu
        gpu = reading.gpu
        memory = reading.memory
        thermal = ProcessInfo.processInfo.thermalState
        func push(_ value: Double, _ history: inout [Double]) {
            history.append(value)
            if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
        }
        push(reading.cpu, &cpuHistory)
        push(reading.gpu ?? 0, &gpuHistory)
        push(reading.memory.fraction, &memoryHistory)
        if let totals = reading.network {
            if let last = lastNetwork {
                let rate = NetworkRate.rate(previous: last.totals, current: totals, seconds: reading.date.timeIntervalSince(last.date))
                networkDown = rate.down
                networkUp = rate.up
                push(rate.down, &networkHistory)
            }
            lastNetwork = (totals, reading.date)
        }
        if detailed {
            processes = reading.processes
            regroup()
        }
        let fire = alert.update(cpu: reading.cpu, pressure: reading.memory.pressure, now: reading.date)
        if alert.level != alertLevel { withAnimation(Theme.snappy) { alertLevel = alert.level } }
        if fire { await announce(reading) }
    }

    /// The one-time sneak: what's tight and who takes the most of it.
    private func announce(_ reading: SystemSampler.Reading) async {
        let sampler = self.sampler
        // A fresh process list for the culprit (the background sample skips it).
        let detail = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: sampler.read(processes: true)) }
        }
        let memoryTight = reading.memory.pressure != .normal
        let top = ProcessGrouping.group(detail.processes, sort: memoryTight ? .memory : .cpu, limit: 1).first
        let title = memoryTight ? (reading.memory.pressure == .critical ? "Memory full" : "Memory tight") : "CPU busy"
        let culprit = top.map { memoryTight ? "\($0.name) \(ByteText.short($0.memory))" : "\($0.name) \(Int(($0.cpu * 100).rounded())) %" }
        onAlert?(title, culprit, alert.level)
    }

    private func regroup() {
        withAnimation(Theme.snappy) { apps = ProcessGrouping.group(processes, sort: sort, limit: 6) }
    }

    func activate(_ app: AppUsage) {
        Haptics.tick()
        if let path = app.bundlePath,
           let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.path == path }) {
            running.activate()
        } else if let path = app.bundlePath {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    /// Switches the whole Mac between light and dark. Previews only flip the switch.
    func toggleDarkMode() {
        Haptics.tick()
        let next = !darkMode
        withAnimation(Theme.snappy) { darkMode = next }
        guard !previewMode else { return }
        DarkMode.set(next) { [weak self] actual, failed in
            guard let self, self.darkMode != actual else { return }
            withAnimation(Theme.snappy) { self.darkMode = actual }
            if failed { self.onDarkModeDenied?() }
        }
    }

    /// Hides or shows the icons on the desktop (Finder restarts). Previews only flip the switch.
    func toggleDesktopIcons() {
        Haptics.tick()
        let next = !desktopHidden
        withAnimation(Theme.snappy) { desktopHidden = next }
        guard !previewMode else { return }
        DesktopIcons.set(hidden: next)
    }

    func openActivityMonitor() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: NotchModule

    /// A load alert, the camera or microphone in use, a battery about to run out, or the Mac
    /// awake with the lid closed (it shouldn't go into a bag unnoticed).
    var needsAttention: Bool { alertLevel != .none || media.inUse || battery?.isLow == true || lidAwakeOn }

    var lidAwakeOn: Bool { lidAwake != .off }

    /// The lid state stays in the ears while it lasts, also when agents work in the first tab.
    var holdsEars: Bool { lidAwakeOn }

    /// Laptops only (a battery means a lid); shown as keep awake's second level.
    var offersLidAwake: Bool { battery != nil && (keepAwake || lidAwakeOn) }

    /// The panel stays open behind the password dialog, so the result shows where it was asked.
    var holdsOpen: Bool { lidBusy }

    /// The camera or microphone in use wins over everything but dictation; tight memory or a
    /// long-busy CPU wins over agents at work; full memory over a meeting soon. Awake with the
    /// lid closed sits above a failed loop and below music (its ear says it anyway).
    var ambientPriority: Int {
        if media.inUse { return 38 }
        switch alertLevel {
        case .none: return battery?.isLow == true ? 25 : lidAwakeOn ? 12 : 0
        case .warn: return 22
        case .critical: return 35
        }
    }

    func setExpanded(_ expanded: Bool) {
        self.expanded = expanded
        if !expanded && !previewMode { lidPickerOpen = false }
        if expanded, !previewMode {
            darkMode = DarkMode.isOn
            desktopHidden = DesktopIcons.hidden
            // Restart the loop so the 2 s cadence (and the app list) starts now, not in 10 s.
            task?.cancel()
            task = nil
            start()
        }
    }

    func leadingEar(peek: Bool) -> AnyView {
        if media.inUse {
            // The main character listens (whole, the handle to pull it out); the dots go right.
            if let cast {
                return AnyView(EarFigure(cast: cast, mood: .listening, height: peek ? 28 : 25, sink: peek ? 0 : 0.25)
                    .frame(height: 32, alignment: .bottom)
                    .help(media.line))
            }
            return AnyView(mediaDots.help(media.line))
        }
        if lidAwakeOn && alertLevel == .none {
            return AnyView(Image(systemName: "laptopcomputer")
                .font(.system(size: peek ? 12.5 : 11.5, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .help(Text(LidAwakeText.line(lidAwake))))
        }
        return AnyView(Image(systemName: battery?.isLow == true && alertLevel == .none ? "battery.25percent" : symbol)
            .font(.system(size: peek ? 12.5 : 11.5, weight: .semibold))
            .foregroundStyle(battery?.isLow == true && alertLevel == .none ? Theme.waiting : Theme.textBody))
    }

    func trailingEar(peek: Bool) -> AnyView {
        if media.inUse {
            return AnyView(HStack(spacing: 5) {
                if cast != nil { mediaDots }
                if peek, let app = media.app {
                    Text(app).font(Theme.font(12, .medium)).foregroundStyle(Theme.textBody).lineLimit(1)
                }
            }.help(media.line))
        }
        if lidAwakeOn && alertLevel == .none {
            return AnyView(LidAwakeEar(state: lidAwake).help(Text(LidAwakeText.line(lidAwake))))
        }
        return AnyView(Circle()
            .fill(alertLevel == .critical ? Theme.critical : Theme.waiting)
            .frame(width: 7, height: 7)
            .opacity(alertLevel == .none ? 0 : 1)
            .help(alertLevel == .none ? "" : "Your Mac is under load"))
    }

    /// The system's own colours: green camera, amber microphone.
    private var mediaDots: some View {
        HStack(spacing: 3) {
            if media.camera { Circle().fill(Theme.ok).frame(width: 7, height: 7) }
            if media.microphone { Circle().fill(Theme.waiting).frame(width: 7, height: 7) }
        }
    }

    func peekLine() -> AnyView {
        AnyView(SystemPeekLine(module: self))
    }

    func body() -> AnyView { AnyView(SystemBody(module: self)) }

    func primaryAction() { openActivityMonitor() }
}

extension MemoryStats.Pressure {
    var color: Color {
        switch self {
        case .normal: Theme.ok
        case .warn: Theme.waiting
        case .critical: Theme.critical
        }
    }

    var word: String {
        switch self {
        case .normal: "Normal"
        case .warn: "Tight"
        case .critical: "Full"
        }
    }
}

extension ProcessInfo.ThermalState {
    var word: String? {
        switch self {
        case .nominal: nil
        case .fair: "Warm"
        case .serious: "Hot"
        case .critical: "Very hot"
        @unknown default: nil
        }
    }
}

enum Percent {
    static func text(_ value: Double) -> String { "\(Int((value * 100).rounded())) %" }
}

private struct SystemPeekLine: View {
    let module: SystemModule

    var body: some View {
        let memory = module.memory
        if module.media.inUse {
            HStack(spacing: 7) {
                Circle().fill(module.media.camera ? Theme.ok : Theme.waiting).frame(width: 7, height: 7)
                ViewThatFits(in: .horizontal) {
                    Text(module.media.line).fixedSize()
                    Text(module.media.shortLine).fixedSize()
                    Text(module.media.app ?? module.media.shortLine)
                }
                .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
            }
            .font(Theme.font(12.5, .medium))
            .lineLimit(1)
        } else if module.lidAwakeOn && module.alertLevel == .none {
            // The ears carry the laptop and the ring; the line says until when.
            HStack(spacing: 7) {
                ViewThatFits(in: .horizontal) {
                    Text(LidAwakeText.line(module.lidAwake)).fixedSize()
                    Text(LidAwakeText.short(module.lidAwake))
                }
                .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
            }
            .font(Theme.font(12.5, .medium))
            .lineLimit(1)
        } else {
            lines(memory)
        }
    }

    @ViewBuilder private func lines(_ memory: MemoryStats?) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { cpu; gpu; mem(memory, withWord: true); Spacer(minLength: 0) }.fixedSize()
            HStack(spacing: 10) { cpu; mem(memory, withWord: false); Spacer(minLength: 0) }.fixedSize()
            HStack(spacing: 10) { cpu; Spacer(minLength: 0) }
        }
        .font(Theme.font(12.5).monospacedDigit())
        .lineLimit(1)
    }

    private var cpu: some View {
        HStack(spacing: 4) {
            Text("CPU").foregroundStyle(Theme.textSecondary)
            Text(Percent.text(module.cpu)).foregroundStyle(module.cpu >= 0.85 ? Theme.waiting : Theme.textPrimary)
        }
    }

    @ViewBuilder private var gpu: some View {
        if let gpu = module.gpu {
            HStack(spacing: 4) {
                Text("GPU").foregroundStyle(Theme.textSecondary)
                Text(Percent.text(gpu)).foregroundStyle(Theme.textPrimary)
            }
        }
    }

    @ViewBuilder private func mem(_ memory: MemoryStats?, withWord: Bool) -> some View {
        if let memory {
            HStack(spacing: 4) {
                Text("Memory").foregroundStyle(Theme.textSecondary)
                Text(Percent.text(memory.fraction)).foregroundStyle(Theme.textPrimary)
                if withWord || memory.pressure != .normal {
                    Circle().fill(memory.pressure.color).frame(width: 5, height: 5)
                }
            }
        }
    }
}

// MARK: Panel

private struct SystemBody: View {
    let module: SystemModule

    /// Four meters in a square on the left, the apps behind them on the right, the switches
    /// along the bottom: the whole panel without scrolling. On a panel narrowed to the menu bar
    /// the square gives up half of what it loses, so the app names keep their room.
    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { proxy in
                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 10) {
                        HStack(spacing: 10) {
                            Meter(title: "CPU", value: module.cpu, history: module.cpuHistory,
                                  detail: "\(ProcessInfo.processInfo.activeProcessorCount) cores",
                                  tint: module.cpu >= 0.85 ? Theme.waiting : Theme.textBody)
                            Meter(title: "GPU", value: module.gpu ?? 0, history: module.gpuHistory,
                                  detail: module.gpu == nil ? "not readable" : "", tint: Theme.textBody)
                        }
                        HStack(spacing: 10) {
                            MemoryMeter(memory: module.memory, history: module.memoryHistory)
                            NetworkMeter(down: module.networkDown, up: module.networkUp, history: module.networkHistory)
                        }
                    }
                    .frame(width: min(280, 280 - (NotchLayout.expandedWidth - 2 * NotchLayout.sideInset - proxy.size.width) / 2))
                    TopApps(module: module)
                }
            }
            StatusChips(module: module)
                .frame(height: 28)
        }
    }
}

/// A number, a quiet sparkline of the last two minutes, one line of context.
private struct Meter: View {
    let title: String
    let value: Double
    let history: [Double]
    let detail: String
    let tint: Color

    var body: some View {
        NotchCard(padding: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(Theme.font(11.5, .semibold)).foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 4)
                    Text(detail).font(Theme.font(11)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                Text(Percent.text(value))
                    .font(Theme.font(22, .semibold).monospacedDigit())
                    .foregroundStyle(tint == Theme.textBody ? Theme.textPrimary : tint)
                    .contentTransition(.numericText())
                Sparkline(values: history, tint: tint)
                    .frame(maxHeight: .infinity)
            }
        }
    }
}

private struct MemoryMeter: View {
    let memory: MemoryStats?
    let history: [Double]

    var body: some View {
        NotchCard(padding: 12) {
            VStack(alignment: .leading, spacing: 4) {
                // The pressure word steps aside on a narrow card; its dot stays.
                ViewThatFits(in: .horizontal) {
                    header(word: true)
                    header(word: false)
                }
                if let memory {
                    // The number stays whole; "of 24 GB" goes first when the card is narrow.
                    let used = Text(ByteText.short(memory.used)).font(Theme.font(22, .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            used
                            Text("of \(ByteText.short(memory.total))").font(Theme.font(11.5)).foregroundStyle(Theme.textTertiary)
                        }
                        used
                    }
                    .lineLimit(1)
                    Sparkline(values: history, tint: memory.pressure == .normal ? Theme.textBody : memory.pressure.color)
                        .frame(maxHeight: .infinity)
                    ViewThatFits(in: .horizontal) {
                        Text(memory.swapUsed > 0 ? "Swap \(ByteText.short(memory.swapUsed)) · compressed \(ByteText.short(memory.compressed))"
                                                 : "Compressed \(ByteText.short(memory.compressed))")
                        Text(memory.swapUsed > 0 ? "Swap \(ByteText.short(memory.swapUsed))" : "Compressed \(ByteText.short(memory.compressed))")
                    }
                        .font(Theme.font(10.5)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                        .help("App \(ByteText.short(memory.app)) · wired \(ByteText.short(memory.wired)) · compressed \(ByteText.short(memory.compressed)) · swap \(ByteText.short(memory.swapUsed))")
                }
            }
        }
    }

    private func header(word: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text("Memory").font(Theme.font(11.5, .semibold)).foregroundStyle(Theme.textSecondary).fixedSize()
            Spacer(minLength: 4)
            if let memory {
                Circle().fill(memory.pressure.color).frame(width: 6, height: 6)
                if word {
                    Text(memory.pressure.word).font(Theme.font(11)).foregroundStyle(memory.pressure == .normal ? Theme.textTertiary : memory.pressure.color)
                        .fixedSize()
                }
            }
        }
    }
}

/// Download speed large, a line of the last two minutes scaled to its own peak (at least
/// 256 KB/s, so an idle line stays flat), upload small underneath.
private struct NetworkMeter: View {
    let down: Double?
    let up: Double?
    let history: [Double]

    var body: some View {
        NotchCard(padding: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Network").font(Theme.font(11.5, .semibold)).foregroundStyle(Theme.textSecondary)
                Text(down.map { "↓ \(ByteText.rate($0))" } ?? "–")
                    .font(Theme.font(22, .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                let peak = max(262_144, history.max() ?? 0)
                Sparkline(values: history.map { $0 / peak }, tint: Theme.textBody)
                    .frame(maxHeight: .infinity)
                if let up {
                    Text("↑ \(ByteText.rate(up))").font(Theme.font(10.5).monospacedDigit()).foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
        }
        .help("Wi-Fi and Ethernet, down and up")
    }
}

/// A line over the last two minutes with a faint fill, scaled 0 to 100 %.
private struct Sparkline: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let points = self.points(in: proxy.size)
            ZStack {
                if points.count > 1 {
                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: proxy.size.height))
                        for point in points { path.addLine(to: point) }
                        path.addLine(to: CGPoint(x: points.last!.x, y: proxy.size.height))
                        path.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [tint.opacity(0.18), tint.opacity(0)], startPoint: .top, endPoint: .bottom))
                    Path { path in
                        path.move(to: points[0])
                        for point in points.dropFirst() { path.addLine(to: point) }
                    }
                    .stroke(tint.opacity(0.75), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func points(in size: CGSize) -> [CGPoint] {
        let count = SystemModule.historyLength
        let step = size.width / CGFloat(max(1, count - 1))
        let offset = count - values.count
        return values.enumerated().map { index, value in
            CGPoint(x: CGFloat(index + offset) * step, y: size.height * (1 - CGFloat(min(1, max(0, value)))) * 0.92 + 1)
        }
    }
}

private struct TopApps: View {
    let module: SystemModule
    @Namespace private var toggle

    var body: some View {
        NotchCard(padding: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("Top apps").font(Theme.font(11.5, .semibold)).foregroundStyle(Theme.textSecondary)
                    if let word = module.thermal.word {
                        HStack(spacing: 4) {
                            Image(systemName: "thermometer.medium").font(.system(size: 10, weight: .semibold))
                            Text(word)
                        }
                        .font(Theme.font(11, .medium))
                        .foregroundStyle(module.thermal == .fair ? Theme.textSecondary : Theme.waiting)
                        .help("Thermal state: \(word)")
                    }
                    Spacer(minLength: 6)
                    HStack(spacing: 2) {
                        option("CPU", .cpu)
                        option("Memory", .memory)
                    }
                    .padding(2)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    // 28 pt to hit; the row keeps the height of the CPU and Memory switch.
                    Button { module.openActivityMonitor() } label: {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScale())
                    .help("Open Activity Monitor")
                    .padding(.vertical, -3)
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 4)
                if module.apps.isEmpty {
                    Text("Reading the apps…").font(Theme.font(12)).foregroundStyle(Theme.textTertiary).padding(.horizontal, 6)
                }
                ForEach(module.apps) { app in
                    AppRow(app: app, sort: module.sort) { module.activate(app) }
                        .transition(.opacity)
                }
            }
        }
    }

    private func option(_ title: String, _ sort: ProcessGrouping.Sort) -> some View {
        let selected = module.sort == sort
        return Button {
            Haptics.tick()
            withAnimation(Theme.snappy) { module.sort = sort }
        } label: {
            Text(title)
                .font(Theme.font(11, selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                .padding(.horizontal, 7)
                .frame(height: 18)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.white.opacity(0.12))
                            .matchedGeometryEffect(id: "sort", in: toggle)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
    }
}

private struct AppRow: View {
    let app: AppUsage
    let sort: ProcessGrouping.Sort
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                icon.frame(width: 18, height: 18)
                // The process count steps aside before the name would be cut.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        name.fixedSize()
                        if app.processes > 1 {
                            Text("\(app.processes)").font(Theme.font(10.5).monospacedDigit()).foregroundStyle(Theme.textTertiary)
                                .help("\(app.processes) processes")
                        }
                    }
                    name
                }
                Spacer(minLength: 6)
                Text(Percent.text(app.cpu))
                    .font(Theme.font(12).monospacedDigit())
                    .foregroundStyle(sort == .cpu ? Theme.textPrimary : Theme.textSecondary)
                    .frame(width: 44, alignment: .trailing)
                Text(ByteText.short(app.memory))
                    .font(Theme.font(12).monospacedDigit())
                    .foregroundStyle(sort == .memory ? Theme.textPrimary : Theme.textSecondary)
                    .frame(width: 56, alignment: .trailing)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .opacity(hovering && app.bundlePath != nil ? 1 : 0)
                    .frame(width: 10)
            }
            .padding(.horizontal, 6)
            .frame(height: 26)
            .background(Color.white.opacity(hovering ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .onHover { hovering = $0 }
        .help(app.bundlePath == nil ? app.name : "Bring \(app.name) forward")
    }

    private var name: some View {
        Text(app.name).font(Theme.font(12.5, .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
    }

    @ViewBuilder private var icon: some View {
        if let path = app.bundlePath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().interpolation(.high)
        } else if app.key == "claude-code" {
            Image(systemName: "terminal").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
        } else {
            Image(systemName: "gearshape").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textTertiary)
        }
    }
}

/// One quiet row: battery, the camera or microphone in use and long terminal commands on the
/// left; the switches (keep awake, dark mode, desktop icons) on the right. Status gives way first.
/// While keep awake is on, a laptop gets its second level beside it: also with the lid closed,
/// chosen for a time in the same row.
private struct StatusChips: View {
    let module: SystemModule

    var body: some View {
        ZStack {
            if module.lidPickerOpen && module.offersLidAwake && !module.lidAwakeOn {
                LidAwakePicker(module: module) { withAnimation(Theme.snappy) { module.lidPickerOpen = false } }
                    .transition(.opacity)
            } else {
                ViewThatFits(in: .horizontal) {
                    row(.all)
                    row(.lit)
                    row(.none)
                }
                .transition(.opacity)
            }
        }
    }

    /// Which switches keep their title as room runs out: all, the ones that are on, none.
    private enum Titles { case all, lit, none }

    private func row(_ titles: Titles) -> some View {
        func labels(_ on: Bool) -> Bool { titles == .all || (titles == .lit && on) }
        return HStack(spacing: 8) {
            if let battery = module.battery {
                chip(symbol: battery.charging ? "battery.100percent.bolt" : battery.percent <= 20 ? "battery.25percent" : "battery.75percent",
                     text: battery.charging ? "\(battery.percent) % · charging" : battery.pluggedIn ? "\(battery.percent) % · on power" : "\(battery.percent) %",
                     tint: battery.isLow ? Theme.waiting : Theme.textBody)
                    .help(battery.line)
            }
            if module.media.inUse {
                HStack(spacing: 6) {
                    Circle().fill(module.media.camera ? Theme.ok : Theme.waiting).frame(width: 7, height: 7)
                    Text(module.media.shortLine).font(Theme.font(12, .medium)).foregroundStyle(Theme.textBody)
                }
                .padding(.horizontal, 10).frame(height: 28)
                .background(Color.white.opacity(0.06), in: Capsule())
            }
            if let command = module.longCommands.first {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    chip(symbol: "terminal", text: "\(command.command) · \(Durations.short(context.date.timeIntervalSince(command.start)))",
                         tint: Theme.textBody)
                }
                .help(module.longCommands.map { "\($0.command) in \(($0.cwd as NSString).lastPathComponent)" }.joined(separator: "\n"))
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if module.offersKeepAwake {
                    toggle(module.keepAwake ? "cup.and.heat.waves.fill" : "cup.and.saucer", labels(module.keepAwake) ? "Keep awake" : nil, on: module.keepAwake,
                           help: module.keepAwake ? "The display stays on until you switch this off" : "Keep the display and the Mac awake") {
                        module.onToggleKeepAwake?()
                    }
                }
                if module.offersKeepAwake, module.offersLidAwake {
                    lidToggle(labels: labels(module.lidAwakeOn))
                        .transition(.opacity)
                }
                if module.onToggleMemory != nil {
                    toggle(module.memoryPaused ? "pause.circle.fill" : "pause.circle",
                           labels(module.memoryPaused) ? (module.memoryPaused ? "Memory paused" : "Pause memory") : nil,
                           on: module.memoryPaused,
                           help: module.memoryPaused ? "Tara's memory is paused: nothing new is recorded. Click to resume"
                                                     : "Pause Tara's memory: no meetings, captures, notes or clipboard until you resume") {
                        module.onToggleMemory?()
                    }
                }
                toggle(module.darkMode ? "moon.fill" : "moon", labels(module.darkMode) ? "Dark mode" : nil, on: module.darkMode,
                       help: "Switch the whole Mac between light and dark") {
                    module.toggleDarkMode()
                }
                toggle(module.desktopHidden ? "eye.slash" : "menubar.dock.rectangle", labels(module.desktopHidden) ? "Hide icons" : nil, on: module.desktopHidden,
                       help: "Hide the icons on the desktop. Finder restarts to apply it, which stops a copy in progress") {
                    module.toggleDesktopIcons()
                }
            }
            .fixedSize()
            .layoutPriority(1)
        }
        .lineLimit(1)
    }

    /// A switch as a capsule: the accent while on. Without a title (little room) the icon alone,
    /// the title in its tooltip.
    private func toggle(_ symbol: String, _ title: LocalizedStringKey?, on: Bool, help: LocalizedStringKey,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                if let title { Text(title).font(Theme.font(12, .medium)) }
            }
            .modifier(SwitchCapsule(on: on, titled: title != nil))
        }
        .buttonStyle(PressScale())
        .help(Text(help))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Off: opens the time choice in this row. On: what's left (∞: until switched off); a click
    /// switches it off.
    private func lidToggle(labels: Bool) -> some View {
        let on = module.lidAwakeOn
        return Button {
            if on { module.onLidAwake?(nil) } else { withAnimation(Theme.snappy) { module.lidPickerOpen = true } }
        } label: {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                HStack(spacing: 6) {
                    if module.lidBusy {
                        ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "laptopcomputer").font(.system(size: 11, weight: .semibold))
                    }
                    if labels {
                        let left = on ? LidAwake(state: module.lidAwake).remaining(now: context.date) : nil
                        (Text("Lid closed") + Text(verbatim: left.map { " · " + Durations.short(max(60, $0)) } ?? ""))
                            .font(Theme.font(12, .medium).monospacedDigit())
                        if on && left == nil {
                            Image(systemName: "infinity").font(.system(size: 9.5, weight: .semibold))
                        }
                    }
                }
                .modifier(SwitchCapsule(on: on, titled: labels))
            }
        }
        .buttonStyle(PressScale())
        .disabled(module.lidBusy)
        .help(on ? Text(LidAwakeText.line(module.lidAwake)) + Text(verbatim: " · ") + Text("Click to switch off")
                 : Text("Also stay awake with the lid closed"))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func chip(symbol: String, text: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
            Text(text).font(Theme.font(12, .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Color.white.opacity(0.06), in: Capsule())
    }
}

/// The look every switch in the row shares: a capsule, the accent while on.
private struct SwitchCapsule: ViewModifier {
    let on: Bool
    let titled: Bool

    func body(content: Content) -> some View {
        content
            .foregroundStyle(on ? Theme.accent : Theme.textSecondary)
            .padding(.horizontal, titled ? 10 : 0)
            .frame(minWidth: 34)
            .frame(height: 28)
            .background(on ? Theme.accent.opacity(0.14) : Color.white.opacity(0.06), in: Capsule())
            .contentShape(Capsule())
    }
}

/// The lid's time choice, in place of the switches: 1 h, 3 h or until switched off, and the
/// battery floor. On battery a note says it stays warm with the lid closed, so not in a bag.
private struct LidAwakePicker: View {
    let module: SystemModule
    let close: () -> Void

    var body: some View {
        let onBattery = module.battery?.pluggedIn == false
        HStack(spacing: 8) {
            Image(systemName: "laptopcomputer").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent)
                .padding(.leading, 4)
            if !onBattery {
                // The words where they fit, else the short form: the row keeps the floor.
                ViewThatFits(in: .horizontal) {
                    Text("Stay awake with the lid closed for").fixedSize()
                    Text("For").fixedSize()
                }
                .font(Theme.font(12, .medium)).foregroundStyle(Theme.textBody)
                .layoutPriority(2)
            }
            ForEach(LidAwakeLimit.allCases, id: \.self) { limit in
                Button {
                    module.onLidAwake?(limit)
                    close()
                } label: {
                    capsule(Text(LidAwakeText.title(limit)))
                }
                .buttonStyle(PressScale())
                .fixedSize()
            }
            // The floor: each click picks the next one (10, 20, 30, 50 %).
            Button {
                let floors = LidAwake.floors
                module.lidFloor = floors[((floors.firstIndex(of: module.lidFloor) ?? 0) + 1) % floors.count]
            } label: {
                capsule(Text("Stops at") + Text(verbatim: " \(module.lidFloor) %"))
            }
            .buttonStyle(PressScale())
            .fixedSize()
            .help("On battery it stops at this charge. Click for another: 10, 20, 30 or 50 percent")
            Spacer(minLength: 8)
            if onBattery {
                // The words where they fit, else the warning sign that says it in its tooltip.
                ViewThatFits(in: .horizontal) {
                    Text("Awake and warm with the lid closed: not in a bag").fixedSize()
                    Text("Warm with the lid closed: not in a bag").fixedSize()
                    Text("Not in a bag").fixedSize()
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 11, weight: .semibold)).frame(width: 28, height: 28)
                }
                .font(Theme.font(11))
                .foregroundStyle(Theme.waiting)
                .help("The Mac stays awake and warm with the lid closed, so not in a bag. Keeping it awake ends when the battery reaches the floor.")
                .layoutPriority(1)
                if module.lidNeedsPassword() {
                    Image(systemName: "lock").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                        .frame(width: 28, height: 28)
                        .help("Asks for your password once")
                }
            } else if module.lidNeedsPassword() {
                // The words where they fit, else the lock that says it in its tooltip.
                ViewThatFits(in: .horizontal) {
                    Text("Asks for your password once").fixedSize()
                    Image(systemName: "lock").font(.system(size: 11, weight: .semibold)).frame(width: 28, height: 28)
                }
                .font(Theme.font(11))
                .foregroundStyle(Theme.textTertiary)
                .help("Asks for your password once")
                .layoutPriority(1)
            }
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.06), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(PressScale())
            .help("Cancel")
        }
        .lineLimit(1)
    }

    private func capsule(_ text: Text) -> some View {
        text.font(Theme.font(12, .medium)).foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Color.white.opacity(0.08), in: Capsule())
            .contentShape(Capsule())
    }
}

/// The ear while awake with the lid closed: a ring that empties toward the limit, or ∞ when it
/// lasts until switched off.
private struct LidAwakeEar: View {
    let state: LidAwake.State

    var body: some View {
        if case .on(let since, let until?) = state {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let total = max(1, until.timeIntervalSince(since))
                let left = max(0, min(1, until.timeIntervalSince(context.date) / total))
                ZStack {
                    Circle().stroke(Theme.accent.opacity(0.22), lineWidth: 2)
                    Circle().trim(from: 0, to: left)
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 11, height: 11)
            }
        } else {
            Image(systemName: "infinity").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accent)
        }
    }
}

/// The lid's words, in one place (English keys, German in Localizable.strings).
enum LidAwakeText {
    static func line(_ state: LidAwake.State) -> LocalizedStringKey {
        if case .on(_, let until?) = state {
            return "Awake with the lid closed until \(until.formatted(date: .omitted, time: .shortened))"
        }
        return "Awake with the lid closed until you switch it off"
    }

    /// For the narrow peek.
    static func short(_ state: LidAwake.State) -> LocalizedStringKey {
        if case .on(_, let until?) = state {
            return "Lid closed until \(until.formatted(date: .omitted, time: .shortened))"
        }
        return "Lid closed until switched off"
    }

    static func title(_ limit: LidAwakeLimit) -> LocalizedStringKey {
        switch limit {
        case .oneHour: "1 h"
        case .threeHours: "3 h"
        case .untilOff: "Until off"
        }
    }
}
