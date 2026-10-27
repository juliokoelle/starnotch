import AppKit
import NotchCore
import Observation
import SwiftUI

/// Is the Mac overloaded, and by what? CPU, GPU and memory with a two-minute history, and the
/// apps behind them (helpers summed into their app). Samples every 2 s while the panel is open,
/// every 10 s otherwise (CPU and memory only, for the warning). Nothing is ever quit from here.
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
    @ObservationIgnored var onToggleKeepAwake: (() -> Void)?
    /// Terminal commands running for 30 s or more (from the shell snippet).
    var longCommands: [ShellActivity.Running] = []
    @ObservationIgnored private var mediaTask: Task<Void, Never>?
    var sort = ProcessGrouping.Sort.cpu {
        didSet { if sort != oldValue { regroup() } }
    }

    /// One sneak per overload episode ("Memory tight · Google Chrome 3.1 GB").
    @ObservationIgnored var onAlert: ((String, String?, SystemAlert.Level) -> Void)?

    @ObservationIgnored private let sampler = SystemSampler()
    @ObservationIgnored private let queue = DispatchQueue(label: Brand.identifier + ".system", qos: .utility)
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var expanded = false
    @ObservationIgnored private var alert = SystemAlert()
    @ObservationIgnored private var processes: [ProcessSample] = []
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
    func usePreview(cpu: [Double], gpu: [Double], memory: MemoryStats, apps: [AppUsage]) {
        previewMode = true
        task?.cancel()
        task = nil
        cpuHistory = cpu
        gpuHistory = gpu
        self.cpu = cpu.last ?? 0
        self.gpu = gpu.last
        self.memory = memory
        memoryHistory = Array(repeating: memory.fraction, count: Self.historyLength)
        self.apps = apps
        alertLevel = memory.pressure == .critical ? .critical : memory.pressure == .warn ? .warn : .none
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
        withAnimation(Theme.snappy) { apps = ProcessGrouping.group(processes, sort: sort, limit: 5) }
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

    func openActivityMonitor() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: NotchModule

    /// A load alert, the camera or microphone in use, or a battery about to run out.
    var needsAttention: Bool { alertLevel != .none || media.inUse || battery?.isLow == true }

    /// The camera or microphone in use wins over everything but dictation; tight memory or a
    /// long-busy CPU wins over agents at work; full memory over a meeting soon.
    var ambientPriority: Int {
        if media.inUse { return 38 }
        switch alertLevel {
        case .none: return battery?.isLow == true ? 25 : 0
        case .warn: return 22
        case .critical: return 35
        }
    }
    var bodyHeight: CGFloat { 312 + 44 }

    func setExpanded(_ expanded: Bool) {
        self.expanded = expanded
        if expanded, !previewMode {
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
                return AnyView(AvatarView(character: cast.main, mood: .listening, height: peek ? 28 : 25,
                                          colorway: cast.colorway, sink: peek ? 0 : 0.25)
                    .frame(height: 32, alignment: .bottom)
                    .help(media.line))
            }
            return AnyView(mediaDots.help(media.line))
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

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Meter(title: "CPU", value: module.cpu, history: module.cpuHistory,
                      detail: "\(ProcessInfo.processInfo.activeProcessorCount) cores",
                      tint: module.cpu >= 0.85 ? Theme.waiting : Theme.textBody)
                Meter(title: "GPU", value: module.gpu ?? 0, history: module.gpuHistory,
                      detail: module.gpu == nil ? "not readable" : "", tint: Theme.textBody)
                MemoryMeter(memory: module.memory, history: module.memoryHistory)
            }
            .frame(height: 112)
            StatusChips(module: module)
                .frame(height: 34)
            TopApps(module: module)
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
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("Memory").font(Theme.font(11.5, .semibold)).foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 4)
                    if let memory {
                        Circle().fill(memory.pressure.color).frame(width: 6, height: 6)
                        Text(memory.pressure.word).font(Theme.font(11)).foregroundStyle(memory.pressure == .normal ? Theme.textTertiary : memory.pressure.color)
                    }
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
                    QuietLink(title: "Activity Monitor") { module.openActivityMonitor() }
                        .lineLimit(1)
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
                Text(app.name).font(Theme.font(12.5, .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                if app.processes > 1 {
                    Text("\(app.processes)").font(Theme.font(10.5).monospacedDigit()).foregroundStyle(Theme.textTertiary)
                        .help("\(app.processes) processes")
                }
                Spacer(minLength: 6)
                Text(Percent.text(app.cpu))
                    .font(Theme.font(12).monospacedDigit())
                    .foregroundStyle(sort == .cpu ? Theme.textPrimary : Theme.textSecondary)
                    .frame(width: 58, alignment: .trailing)
                Text(ByteText.short(app.memory))
                    .font(Theme.font(12).monospacedDigit())
                    .foregroundStyle(sort == .memory ? Theme.textPrimary : Theme.textSecondary)
                    .frame(width: 64, alignment: .trailing)
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

/// One quiet row: battery, keep awake, the camera or microphone in use, long terminal commands.
private struct StatusChips: View {
    let module: SystemModule

    var body: some View {
        HStack(spacing: 8) {
            if let battery = module.battery {
                chip(symbol: battery.charging ? "battery.100percent.bolt" : battery.percent <= 20 ? "battery.25percent" : "battery.75percent",
                     text: battery.charging ? "\(battery.percent) % · charging" : battery.pluggedIn ? "\(battery.percent) % · on power" : "\(battery.percent) %",
                     tint: battery.isLow ? Theme.waiting : Theme.textBody)
                    .help(battery.line)
            }
            Button { module.onToggleKeepAwake?() } label: {
                Image(systemName: module.keepAwake ? "cup.and.heat.waves.fill" : "cup.and.saucer")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(module.keepAwake ? Theme.accent : Theme.textSecondary)
                    .frame(width: 34, height: 28)
                    .background(module.keepAwake ? Theme.accent.opacity(0.14) : Color.white.opacity(0.06), in: Capsule())
            }
            .buttonStyle(PressScale())
            .help(module.keepAwake ? "The display stays on until you switch this off" : "Keep the display and the Mac awake")
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
        }
        .lineLimit(1)
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
