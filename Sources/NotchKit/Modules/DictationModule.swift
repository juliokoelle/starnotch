import AppKit
import CoreAudio
import NotchCore
import Observation
import SwiftUI

/// One click starts Wispr Flow's hands-free dictation.
///
/// Wispr Flow registers the `wispr-flow://` URL scheme and handles `start-hands-free` and
/// `stop-hands-free` without showing its window, so no Accessibility permission and no
/// synthesized Fn key are needed. The text lands wherever the cursor is, because the notch
/// panel never takes focus from the frontmost app.
///
/// Listening is detected through Core Audio: while the default input device runs, someone is
/// recording. That's only checked after we started dictation, so a call in another app doesn't
/// light up the notch.
@MainActor
@Observable
final class DictationModule: NotchModule {
    enum Phase: Equatable {
        case idle
        /// URL sent, microphone not running yet.
        case starting
        case listening(since: Date)
        /// The microphone never came up; shown briefly as a plain confirmation.
        case sent
        case unavailable
    }

    let kind = ModuleKind.dictation
    let symbol = ModuleSymbols.symbol(.dictation)
    static let bundleID = "com.electron.wispr-flow"

    private(set) var phase = Phase.idle
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    let cast: AvatarCast

    init(cast: AvatarCast) {
        self.cast = cast
    }

    var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) != nil }

    var isActive: Bool {
        switch phase {
        case .starting, .listening, .sent: true
        case .idle, .unavailable: false
        }
    }

    func toggle() {
        switch phase {
        case .listening, .starting: stop()
        case .idle, .sent, .unavailable: start()
        }
    }

    func start() {
        guard isInstalled else {
            set(.unavailable)
            return
        }
        open("wispr-flow://start-hands-free")
        Haptics.confirm()
        set(.starting)
        watch()
    }

    func stop() {
        open("wispr-flow://stop-hands-free")
        Haptics.tick()
        watchTask?.cancel()
        set(.idle)
    }

    private func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false  // keep the cursor where the text should go
        NSWorkspace.shared.open(url, configuration: configuration) { _, error in
            if let error { Log.app.error("Wispr Flow: \(error.localizedDescription, privacy: .public)") }
        }
    }

    /// Follows the microphone for this one dictation, four times a second, then stops polling.
    private func watch() {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            let started = Date()
            var sawMic = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                let running = Microphone.isRunningSomewhere
                if running, !sawMic {
                    sawMic = true
                    self.set(.listening(since: Date()))
                } else if !running, sawMic {
                    self.set(.idle)  // Wispr finished and is pasting
                    return
                } else if !sawMic, Date().timeIntervalSince(started) > 2.5 {
                    self.set(.sent)
                    try? await Task.sleep(for: .seconds(1.4))
                    if self.phase == .sent { self.set(.idle) }
                    return
                }
                if Date().timeIntervalSince(started) > 15 * 60 { self.set(.idle); return }
            }
        }
    }

    private func set(_ phase: Phase) {
        withAnimation(Theme.peek) { self.phase = phase }
    }

    // MARK: NotchModule

    var ambientPriority: Int { isActive ? 40 : 0 }
    var needsAttention: Bool { isActive }
    var earShowsFigure: Bool { true }
    var bodyHeight: CGFloat { 120 }

    /// The main character puts its headphones on while listening.
    func leadingEar(peek: Bool) -> AnyView {
        AnyView(AvatarView(character: cast.main, mood: phaseIsListening ? .listening : .thinking,
                           height: peek ? 28 : 25, colorway: cast.colorway, sink: peek ? 0 : 0.25)
            .frame(height: 32, alignment: .bottom)
            .clipped())
    }

    func trailingEar(peek: Bool) -> AnyView {
        AnyView(Group {
            switch phase {
            case .listening(let since):
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Durations.short(context.date.timeIntervalSince(since)))
                        .font(Theme.font(12, .medium).monospacedDigit())
                        .foregroundStyle(Theme.accent)
                }
            case .sent:
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.ok)
            default:
                Circle().fill(Theme.accent).frame(width: 6, height: 6)
            }
        })
    }

    var phaseIsListening: Bool {
        if case .listening = phase { return true }
        return false
    }

    func peekLine() -> AnyView {
        let text = Text(peekText).font(Theme.font(13, .medium)).foregroundStyle(Theme.textPrimary)
        return AnyView(ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                text.fixedSize()
                Spacer()
                Text("Wispr Flow").font(Theme.font(12)).foregroundStyle(Theme.textSecondary).fixedSize()
            }
            HStack { text; Spacer(minLength: 0) }
        }
        .lineLimit(1))
    }

    private var peekText: String {
        switch phase {
        case .idle: "Click to dictate"
        case .starting: "Starting…"
        case .listening: "Listening, click to stop"
        case .sent: "Sent to Wispr Flow"
        case .unavailable: "Wispr Flow isn't installed"
        }
    }

    func body() -> AnyView { AnyView(DictationBody(module: self)) }

    func primaryAction() { toggle() }
}

private struct DictationBody: View {
    let module: DictationModule

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            AvatarView(character: module.cast.main, mood: .listening, height: 96, colorway: module.cast.colorway,
                       emergeOnAppear: false)
                .frame(width: 112, alignment: .bottom)
                .padding(.leading, 6)
            HStack(spacing: 16) {
                Button {
                    module.toggle()
                } label: {
                    ZStack {
                        Circle().fill(module.phaseIsListening ? Theme.accent : Theme.accent.opacity(0.16))
                        ListeningGlyph(active: module.phaseIsListening, size: 18, tint: module.phaseIsListening ? .white : Theme.accent)
                    }
                    .frame(width: 48, height: 48)
                    .overlay {
                        if module.phaseIsListening { Pulse() }
                    }
                }
                .buttonStyle(PressScale())
                .accessibilityLabel(module.phaseIsListening ? "Stop dictation" : "Start dictation")

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(Theme.font(14, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .contentTransition(.opacity)
                    Text(subtitle)
                        .font(Theme.font(12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(.leading, 130)
            .padding(.trailing, 16)
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var title: String {
        switch module.phase {
        case .idle: "Dictate"
        case .starting: "Starting…"
        case .listening: "Listening"
        case .sent: "Sent to Wispr Flow"
        case .unavailable: "Wispr Flow isn't installed"
        }
    }

    private var subtitle: String {
        switch module.phase {
        case .listening: "Talk. Click again to stop, the text goes where your cursor is."
        case .unavailable: "Install Wispr Flow to dictate from the notch."
        default: "Click and talk, the text goes where your cursor is. Wispr Flow hands-free; holding fn still works."
        }
    }
}

/// Five bars that move while listening and rest as a mic-like stack otherwise.
struct ListeningGlyph: View {
    let active: Bool
    var size: CGFloat
    var tint: Color = Theme.accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !active || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: size * 0.12) {
                ForEach(0..<5, id: \.self) { index in
                    let rest: [Double] = [0.35, 0.6, 1, 0.6, 0.35]
                    let wave = active && !reduceMotion ? 0.3 + 0.7 * abs(sin(t * 5 + Double(index) * 1.3)) : rest[index]
                    Capsule()
                        .fill(tint)
                        .frame(width: size * 0.13, height: size * wave)
                }
            }
            .frame(width: size, height: size)
        }
    }
}

private struct Pulse: View {
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .strokeBorder(Theme.accent.opacity(expanded ? 0 : 0.6), lineWidth: 2)
            .scaleEffect(expanded ? 1.6 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) { expanded = true }
            }
            .allowsHitTesting(false)
    }
}

/// Whether the default input device is in use by any process (no microphone permission needed).
enum Microphone {
    static var isRunningSomewhere: Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else {
            return false
        }
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }
}
