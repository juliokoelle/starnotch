import CoreAudio
import Foundation
import NotchCore

/// AirPods and other Bluetooth audio: when one becomes the output, its battery (each earbud and
/// the case) shows in the notch, as on the iPhone. Reads `system_profiler` once per connection,
/// off the main thread; nothing polls.
@MainActor
final class HeadphoneBattery {
    var onBattery: ((DeviceBattery) -> Void)?
    private var current: AudioDeviceID = 0
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.outputChanged() }
        }
        current = Self.defaultOutput() ?? 0
    }

    private func outputChanged() {
        guard let device = Self.defaultOutput(), device != current else { return }
        current = device
        guard Self.isBluetooth(device) else { return }
        let name = Self.name(of: device)
        Task.detached(priority: .utility) { [weak self] in
            // The earbuds report their levels a moment after they connect.
            try? await Task.sleep(for: .seconds(1.5))
            guard let data = Self.profile(), let battery = DeviceBattery.parse(data, preferring: name) else { return }
            await MainActor.run { self?.onBattery?(battery) }
        }
    }

    private nonisolated static func profile() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "basic"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    private static func defaultOutput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    private static func isBluetooth(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func name(of device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr, let value = name else { return nil }
        return value.takeRetainedValue() as String
    }
}
