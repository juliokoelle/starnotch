import AudioToolbox
import CoreAudio
import NotchCore
import SwiftUI

/// The output volume and mute of the default output, from CoreAudio property listeners (no
/// polling, no permission). Reports only what the user changed (`LevelHUD.shows`). Display
/// brightness and the keyboard backlight have no public API to read on Apple silicon, so the HUD
/// shows the volume only.
@MainActor
final class VolumeMonitor {
    var onChange: ((LevelReading) -> Void)?
    private let system = AudioObjectID(kAudioObjectSystemObject)
    private var device = AudioObjectID(0)
    private var last: LevelReading?
    /// The listener blocks, kept so they can be removed again (CoreAudio matches them by identity).
    private var defaultListener: AudioObjectPropertyListenerBlock?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var deviceAddresses: [AudioObjectPropertyAddress] = []

    var isRunning: Bool { defaultListener != nil }

    func start() {
        guard defaultListener == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.follow() }
        }
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        guard AudioObjectAddPropertyListenerBlock(system, &address, .main, block) == noErr else { return }
        defaultListener = block
        follow()
    }

    func stop() {
        if let block = defaultListener {
            var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(system, &address, .main, block)
            defaultListener = nil
        }
        unlistenDevice()
        last = nil
    }

    /// The default output changed (or the monitor started): listen to the new one, its level only
    /// as the baseline.
    private func follow() {
        let next = defaultDevice()
        guard next != device || deviceListener == nil else { return }
        unlistenDevice()
        device = next
        guard device != 0 else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.changed() }
        }
        // Volume and mute; an output without a volume (some HDMI displays) has nothing to show.
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
            var address = Self.address(selector, scope: kAudioObjectPropertyScopeOutput)
            if AudioObjectHasProperty(device, &address), AudioObjectAddPropertyListenerBlock(device, &address, .main, block) == noErr {
                deviceAddresses.append(address)
            }
        }
        deviceListener = deviceAddresses.isEmpty ? nil : block
        last = read()
    }

    private func unlistenDevice() {
        if let block = deviceListener {
            for var address in deviceAddresses { AudioObjectRemovePropertyListenerBlock(device, &address, .main, block) }
        }
        deviceListener = nil
        deviceAddresses = []
    }

    private func changed() {
        guard let next = read() else { return }
        let show = LevelHUD.shows(previous: last, next: next)
        last = next
        if show { onChange?(next) }
    }

    private func read() -> LevelReading? {
        guard device != 0 else { return nil }
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput)
        var level = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectHasProperty(device, &address),
              AudioObjectGetPropertyData(device, &address, 0, nil, &size, &level) == noErr else { return nil }
        var muted = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyMute
        if !AudioObjectHasProperty(device, &address) || AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) != noErr {
            muted = 0
        }
        return LevelReading(device: device, level: Double(level), muted: muted != 0)
    }

    private func defaultDevice() -> AudioObjectID {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &id) == noErr else { return 0 }
        return id
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}

/// The speaker and a slim bar, under the notch while the volume changes. Held keys change the
/// value in place: the bar glides, the island doesn't open again.
struct LevelBar: View {
    let reading: LevelReading
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: LevelHUD.symbol(reading))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(reading.muted ? Theme.textSecondary : Theme.textPrimary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 18)
            GeometryReader { proxy in
                Capsule()
                    .fill(Color.white.opacity(0.16))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Theme.textPrimary)
                            .frame(width: proxy.size.width * LevelHUD.fill(reading))
                    }
            }
            .frame(height: 4)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: reading.level)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Volume"))
        .accessibilityValue(reading.muted ? Text("Muted") : Text(verbatim: "\(Int((reading.level * 100).rounded())) %"))
    }
}
