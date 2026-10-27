import AppKit
import AVKit
import AudioToolbox
import CoreAudio
import NotchCore
import Observation
import SwiftUI

/// Audio outputs through CoreAudio: the list, the current device, switching, volume. No
/// permission is needed. AirPlay receivers don't appear as CoreAudio devices until macOS routes
/// to them, so the list ends with the system's AirPlay picker (AVRoutePickerView).
@MainActor
@Observable
final class AudioOutput {
    private(set) var devices: [OutputDevice] = []
    private(set) var current: UInt32?
    private(set) var volume: Double?

    private let system = AudioObjectID(kAudioObjectSystemObject)
    @ObservationIgnored private var listening = false

    init() {
        reload()
    }

    /// Follows device and default changes while the music card shows.
    func startListening() {
        guard !listening else { return }
        listening = true
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(system, &address, .main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.reload() }
            }
        }
    }

    func reload() {
        current = defaultDevice()
        devices = OutputDevice.visible(allDevices(), current: current)
        volume = current.flatMap(readVolume)
    }

    func select(_ device: OutputDevice) {
        Haptics.tick()
        var id = AudioDeviceID(device.id)
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] {
            var address = Self.address(selector)
            AudioObjectSetPropertyData(system, &address, 0, nil, size, &id)
        }
        reload()
    }

    func setVolume(_ value: Double) {
        guard let current else { return }
        var level = Float32(min(1, max(0, value)))
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput)
        guard AudioObjectHasProperty(current, &address) else { return }
        AudioObjectSetPropertyData(current, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &level)
        volume = Double(level)
    }

    var currentDevice: OutputDevice? { devices.first { $0.id == current } }

    // MARK: CoreAudio

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private func defaultDevice() -> UInt32? {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    private func allDevices() -> [OutputDevice] {
        var address = Self.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map { id in
            let name = string(id, kAudioObjectPropertyName) ?? "Output"
            var transport: UInt32 = 0
            var tsize = UInt32(MemoryLayout<UInt32>.size)
            var taddress = Self.address(kAudioDevicePropertyTransportType)
            AudioObjectGetPropertyData(id, &taddress, 0, nil, &tsize, &transport)
            var saddress = Self.address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
            var ssize: UInt32 = 0
            AudioObjectGetPropertyDataSize(id, &saddress, 0, nil, &ssize)
            return OutputDevice(id: id, name: name, kind: OutputDevice.kind(transport: transport, name: name),
                                outputStreams: Int(ssize) / MemoryLayout<AudioStreamID>.size)
        }
    }

    private func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = Self.address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private func readVolume(_ id: UInt32) -> Double? {
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var level: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &level) == noErr else { return nil }
        return Double(level)
    }
}

/// Where the output button sits, so the list can float next to it.
struct OutputButtonAnchor: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// The output button in the music card: the current device's symbol and name; a click opens a
/// small list floating over the card (the island keeps its size, no popover window).
struct OutputButton: View {
    let output: AudioOutput
    @Binding var open: Bool

    var body: some View {
        Button {
            output.reload()
            withAnimation(Theme.snappy) { open.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: output.currentDevice?.kind.symbol ?? "speaker.wave.2")
                    .font(.system(size: 12, weight: .semibold))
                if let name = output.currentDevice?.name {
                    Text(name).font(Theme.font(12, .medium)).lineLimit(1)
                }
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .foregroundStyle(open ? Theme.accent : Theme.textSecondary)
            .padding(.horizontal, 10)
            .frame(maxWidth: 200)
            .frame(height: 28)
            .background(Color.white.opacity(open ? 0.1 : 0.06), in: Capsule())
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .help("Output: \(output.currentDevice?.name ?? "unknown")")
        .accessibilityLabel("Audio output")
        .anchorPreference(key: OutputButtonAnchor.self, value: .bounds) { $0 }
        .onAppear { output.startListening() }
    }
}

/// The floating output list: about 240 pt wide, 28 pt rows, anchored with its lower right corner
/// on the button and growing upward inside the card. More devices than fit scroll; "AirPlay…"
/// always stays the last row. A click anywhere else in the card closes it.
struct OutputPopover: View {
    let output: AudioOutput
    let button: CGRect
    let container: CGSize
    let done: () -> Void
    @State private var airPlay = AirPlayTrigger()

    static let width: CGFloat = 240
    static let row: CGFloat = 28
    private static let inset: CGFloat = 5
    private static let margin: CGFloat = 6

    init(output: AudioOutput, button: CGRect, in container: CGSize, done: @escaping () -> Void) {
        self.output = output
        self.button = button
        self.container = container
        self.done = done
    }

    var body: some View {
        let frame = Self.frame(devices: output.devices.count, button: button, container: container)
        ZStack(alignment: .topLeading) {
            // Clicks elsewhere in the card close the list instead of reaching the controls.
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture(perform: done)
            list(listHeight: frame.height - 2 * Self.inset - Self.row - 9)
                .padding(Self.inset)
                .frame(width: frame.width, height: frame.height, alignment: .top)
                .background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
                .offset(x: frame.minX, y: frame.minY)
                .transition(.scale(scale: 0.94, anchor: .bottomTrailing).combined(with: .opacity))
        }
        .frame(width: container.width, height: container.height, alignment: .topLeading)
    }

    private func list(listHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(output.devices) { device in
                        OutputRow(device: device, selected: device.id == output.current) {
                            output.select(device)
                            done()
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(height: listHeight)
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.vertical, 4).padding(.horizontal, 6)
            // AirPlay receivers only show up through the system picker; the whole row opens it.
            Button { airPlay.open() } label: {
                HStack(spacing: 8) {
                    AirPlayPicker(trigger: airPlay).frame(width: 20, height: 20)
                    Text("AirPlay…").font(Theme.font(12.5)).foregroundStyle(Theme.textBody)
                    Spacer()
                }
                .padding(.horizontal, 6)
                .frame(height: Self.row)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScale())
        }
    }

    /// Lower right corner on the button's lower right corner (a little past it), growing upward,
    /// clamped into the card.
    static func frame(devices: Int, button: CGRect, container: CGSize) -> CGRect {
        let content = 2 * inset + CGFloat(max(devices, 1)) * row + 9 + row
        let height = min(content, container.height - 2 * margin)
        let maxX = min(button.maxX + 4, container.width - margin)
        let maxY = min(button.maxY + 4, container.height - margin)
        let x = max(margin, maxX - width)
        let y = max(margin, maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

private struct OutputRow: View {
    let device: OutputDevice
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: device.kind.symbol)
                    .font(.system(size: 11.5, weight: .medium))
                    .frame(width: 20)
                    .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
                Text(device.name).font(Theme.font(12.5)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer(minLength: 4)
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: OutputPopover.row)
            .background(Color.white.opacity(hovering ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .onHover { hovering = $0 }
    }
}

/// The system's AirPlay route button. Apple's picker opens outside the island, so the island
/// holds its lock from "will begin presenting" to "did end presenting".
/// Lets a SwiftUI row click the route picker's own button.
@MainActor
final class AirPlayTrigger {
    weak var view: AVRoutePickerView?

    func open() {
        guard let view else { return }
        func button(in view: NSView) -> NSButton? {
            if let button = view as? NSButton { return button }
            for sub in view.subviews { if let found = button(in: sub) { return found } }
            return nil
        }
        button(in: view)?.performClick(nil)
    }
}

private struct AirPlayPicker: NSViewRepresentable {
    let trigger: AirPlayTrigger

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        trigger.view = view
        view.isRoutePickerButtonBordered = false
        view.setRoutePickerButtonColor(.white, for: .normal)
        view.setRoutePickerButtonColor(NSColor(Theme.accent), for: .active)
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: AVRoutePickerView, context: Context) {}

    static func dismantleNSView(_ view: AVRoutePickerView, coordinator: Coordinator) {
        coordinator.unlock()
    }

    @MainActor
    final class Coordinator: NSObject, AVRoutePickerViewDelegate {
        private var token: Int?
        private var safety: Task<Void, Never>?

        nonisolated func routePickerViewWillBeginPresentingRoutes(_ view: AVRoutePickerView) {
            MainActor.assumeIsolated {
                if token == nil { token = IslandLock.shared.acquire("airplay picker") }
                // If "did end" never comes, don't keep the island open forever.
                safety?.cancel()
                safety = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(90))
                    self?.unlock()
                }
            }
        }

        nonisolated func routePickerViewDidEndPresentingRoutes(_ view: AVRoutePickerView) {
            MainActor.assumeIsolated { unlock() }
        }

        func unlock() {
            safety?.cancel()
            if let token { IslandLock.shared.release(token) }
            token = nil
        }
    }
}

/// A thin volume line for the current output; `width` nil stretches it to the room it gets.
struct VolumeSlider: View {
    let output: AudioOutput
    var width: CGFloat? = 92

    var body: some View {
        if let volume = output.volume {
            HStack(spacing: 6) {
                Image(systemName: "speaker.fill").font(.system(size: 9)).foregroundStyle(Theme.textTertiary)
                Slider(value: Binding(get: { volume }, set: { output.setVolume($0) }), in: 0...1)
                    .controlSize(.mini)
                    .tint(Color.white.opacity(0.8))
                    .frame(width: width)
                Image(systemName: "speaker.wave.3.fill").font(.system(size: 9)).foregroundStyle(Theme.textTertiary)
            }
            .accessibilityLabel("Volume")
        }
    }
}
