import AppKit
import AudioToolbox
import CoreAudio
import NotchCore
import Observation

/// Volume per app without an audio driver: CoreAudio process taps (macOS 14.2+). An app the user
/// turns down or up gets a private tap that mutes its own output, and a private aggregate device
/// (the current output plus the tap) whose IO block plays the tapped sound again at the chosen
/// level. Apps left at 100 % run untouched, with no tap at all.
///
/// Limits, honestly: macOS asks once for "System Audio Recording" (the tap reads the app's sound,
/// it never leaves the process); a tapped app sounds a few milliseconds later; when the output
/// changes, the taps are rebuilt, with a short gap; apps that play through their own driver or
/// exclusive (hog) mode can't be tapped.
@MainActor
@Observable
final class AppVolumeMixer {
    fileprivate(set) var apps: [AppVolume.App] = []
    fileprivate(set) var levels: AppVolume.Levels
    /// macOS said no to System Audio Recording: the mixer says where to allow it.
    private(set) var denied = false
    /// Sample apps for recordings: levels move, nothing is tapped or saved.
    @ObservationIgnored fileprivate(set) var previewing = false

    @ObservationIgnored private var taps: [String: AppTap] = [:]
    @ObservationIgnored private var listening = false
    /// CoreAudio removes a listener only with the very block it was added with.
    @ObservationIgnored private var listeners: [(selector: AudioObjectPropertySelector, block: AudioObjectPropertyListenerBlock)] = []
    @ObservationIgnored private var refresh: Task<Void, Never>?
    private static let saved = "media.appVolumeLevels"
    private let system = AudioObjectID(kAudioObjectSystemObject)

    /// Process taps came with macOS 14.2.
    static var isSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    init() {
        let data = UserDefaults.standard.data(forKey: Self.saved)
        levels = data.flatMap { try? JSONDecoder().decode(AppVolume.Levels.self, from: $0) } ?? AppVolume.Levels()
    }

    /// While the tool is on: follows apps starting and stopping sound and output changes, and
    /// applies saved levels when their app plays.
    func start() {
        guard Self.isSupported, !listening else { return }
        listening = true
        for selector in [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = Self.address(selector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated {
                    if selector == kAudioHardwarePropertyDefaultOutputDevice { self?.rebuildAll() } else { self?.reload() }
                }
            }
            if AudioObjectAddPropertyListenerBlock(system, &address, .main, block) == noErr { listeners.append((selector, block)) }
        }
        // "Is running output" changes per process without a list change: a slow look while on.
        refresh = Task { [weak self] in
            while !Task.isCancelled {
                self?.reload()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// The tool went off: every app back to its own sound.
    func stop() {
        refresh?.cancel()
        refresh = nil
        for tap in taps.values { tap.stop() }
        taps.removeAll()
        apps = []
        for listener in listeners {
            var address = Self.address(listener.selector)
            AudioObjectRemovePropertyListenerBlock(system, &address, .main, listener.block)
        }
        listeners.removeAll()
        listening = false
    }

    func level(_ app: String) -> Double { levels.level(app) }

    func set(_ level: Double, for app: String) {
        levels.set(level, for: app)
        guard !previewing else { return }
        if let data = try? JSONEncoder().encode(levels) { UserDefaults.standard.set(data, forKey: Self.saved) }
        if let tap = taps[app] {
            if levels.adjusted.contains(app) { tap.gain = Float(levels.level(app)) } else { tap.stop(); taps[app] = nil }
        } else if levels.adjusted.contains(app) {
            ensureAccess { [weak self] in self?.apply() }
        }
    }

    func toggleMute(_ app: String) {
        set(level(app) <= 0.001 ? 1 : 0, for: app)
    }

    // MARK: Processes

    func reload() {
        guard listening else { return }
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        let found = AppVolume.apps(processes(), running: running, adjusted: levels.adjusted, own: Bundle.main.bundleIdentifier)
        if found != apps { apps = found }
        apply()
    }

    /// Taps for the adjusted apps that make sound, none for the rest; a tap whose processes
    /// changed (a browser started a new helper) is rebuilt.
    private func apply() {
        guard listening, !denied else { return }
        let wanted = Dictionary(uniqueKeysWithValues: apps.filter { levels.adjusted.contains($0.bundleID) }.map { ($0.bundleID, $0) })
        for (app, tap) in taps where wanted[app]?.objectIDs.sorted() != tap.objectIDs {
            tap.stop()
            taps[app] = nil
        }
        // Only with System Audio Recording allowed: a tap without it would mute the app and play
        // silence. Not asked yet: the first slider move asks (`ensureAccess`).
        guard !wanted.isEmpty, Self.access == .granted || TCC.preflight == nil else { return }
        for (app, entry) in wanted where taps[app] == nil {
            guard #available(macOS 14.2, *) else { return }
            guard let tap = AppTap(objectIDs: entry.objectIDs.sorted(), gain: Float(levels.level(app))) else { continue }
            taps[app] = tap
        }
    }

    private func rebuildAll() {
        for tap in taps.values { tap.stop() }
        taps.removeAll()
        apply()
    }

    private func processes() -> [AppVolume.Process] {
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            let bundle = Self.string(id, kAudioProcessPropertyBundleID) ?? ""
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = Self.address(kAudioProcessPropertyPID)
            AudioObjectGetPropertyData(id, &pidAddress, 0, nil, &pidSize, &pid)
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            var runningAddress = Self.address(kAudioProcessPropertyIsRunningOutput)
            AudioObjectGetPropertyData(id, &runningAddress, 0, nil, &runningSize, &running)
            // Without a bundle id the process still has a pid: name it after its app.
            let id2 = bundle.isEmpty ? (NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "") : bundle
            return AppVolume.Process(objectID: id, pid: pid, bundleID: id2, isPlaying: running != 0)
        }
    }

    // MARK: Permission

    enum Access { case granted, denied, unknown }

    /// System Audio Recording, through TCC's preflight (the only way to know before a tap plays
    /// silence). Unknown when the call isn't there; the tap then asks on its own.
    static var access: Access {
        guard let preflight = TCC.preflight else { return .unknown }
        switch preflight("kTCCServiceAudioCapture" as CFString, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }

    private func ensureAccess(_ then: @escaping @MainActor () -> Void) {
        switch Self.access {
        case .granted:
            denied = false
            then()
        case .denied:
            denied = true
        case .unknown:
            guard TCC.preflight != nil, let request = TCC.request else { then(); return }
            request("kTCCServiceAudioCapture" as CFString, nil, Self.answer { [weak self] granted in
                self?.denied = !granted
                if granted { then() }
            })
        }
    }

    /// TCC answers on its own queue: built outside the main actor, back on it for the answer.
    private nonisolated static func answer(_ handle: @escaping @MainActor (Bool) -> Void) -> @convention(block) (Bool) -> Void {
        { granted in Task { @MainActor in handle(granted) } }
    }

    func openPrivacySettings() {
        denied = Self.access == .denied
        PrivacyPane.open("Privacy_AudioCapture")
    }

    private enum TCC {
        typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
        typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
        nonisolated(unsafe) static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
        static let preflight: Preflight? = handle.flatMap { dlsym($0, "TCCAccessPreflight") }.map { unsafeBitCast($0, to: Preflight.self) }
        static let request: Request? = handle.flatMap { dlsym($0, "TCCAccessRequest") }.map { unsafeBitCast($0, to: Request.self) }
    }

    // MARK: CoreAudio

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

/// One app's tap: the tap (muting the app's own output), a private aggregate device with the
/// output and the tap, and an IO block that copies the tapped sound to the output at `gain`.
@MainActor
final class AppTap {
    let objectIDs: [UInt32]
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let level: Level

    /// The level, read on the audio thread; a 32-bit store is atomic on Apple silicon and Intel,
    /// so the audio thread sees the old or the new value, never a torn one.
    final class Level: @unchecked Sendable {
        var value: Float
        init(_ value: Float) { self.value = value }
    }

    var gain: Float {
        get { level.value }
        set { level.value = newValue }
    }

    @available(macOS 14.2, *)
    init?(objectIDs: [UInt32], gain: Float) {
        self.objectIDs = objectIDs
        level = Level(gain)
        guard start() else {
            stop()
            return nil
        }
    }

    @available(macOS 14.2, *)
    private func start() -> Bool {
        let description = CATapDescription(stereoMixdownOfProcesses: objectIDs.map { AudioObjectID($0) })
        description.uuid = UUID()
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        description.name = "\(Brand.name) volume"
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr, tapID != kAudioObjectUnknown else {
            Log.app.error("App volume: no tap")
            return false
        }
        // The IO block reads only the tap's channels (its format; a stereo mixdown has 2).
        let tapChannels = Self.channelCount(ofTap: tapID) ?? 2
        guard let (outputID, output) = Self.defaultOutput() else { return false }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "\(Brand.name) volume",
            kAudioAggregateDeviceUIDKey: "\(Brand.identifier).volume.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: output,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else {
            Log.app.error("App volume: no aggregate device")
            return false
        }
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, nil, Self.block(level, tapChannels: tapChannels))
        guard status == noErr, let procID else { return false }
        // An output with inputs of its own (a headset, AirPods, an audio interface) brings its
        // microphone into the aggregate: switched off for this IO block, which never asks for it.
        Self.switchOff(firstInputStreams: Self.inputStreamCount(of: outputID), of: deviceID, for: procID)
        return AudioDeviceStart(deviceID, procID) == noErr
    }

    func stop() {
        if deviceID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(deviceID, procID)
                AudioDeviceDestroyIOProcID(deviceID, procID)
            }
            AudioHardwareDestroyAggregateDevice(deviceID)
        }
        if tapID != kAudioObjectUnknown, #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        deviceID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// Built outside the main actor: CoreAudio calls it on its real-time thread.
    private nonisolated static func block(_ level: Level, tapChannels: Int) -> AudioDeviceIOBlock {
        { _, input, _, output, _ in render(input: input, output: output, gain: level.value, tapChannels: tapChannels) }
    }

    /// Real-time: no allocation, no locks. Float32 samples on both sides (the HAL's IO format),
    /// interleaved or not. The inputs are the output device's own (switched off) and then the tap's.
    private nonisolated static func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>,
                                           gain: Float, tapChannels: Int) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        var inChannels = 0
        for buffer in inputs { inChannels += Int(buffer.mNumberChannels) }
        let tap = AppVolume.tapChannels(inputChannels: inChannels, tapChannels: tapChannels)
        var outChannel = 0
        for buffer in outputs {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let channels = max(1, Int(buffer.mNumberChannels))
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            for c in 0..<channels {
                let source = AppVolume.source(forOutput: outChannel + c, inputChannels: tap.count).map { tap.lowerBound + $0 }
                let feed = source.flatMap { sample(in: inputs, channel: $0) }
                for frame in 0..<frames {
                    var value: Float = 0
                    if let feed, frame < feed.frames { value = AppVolume.apply(gain, to: feed.data[frame * feed.stride + feed.offset]) }
                    data[frame * channels + c] = value
                }
            }
            outChannel += channels
        }
    }

    /// Where input channel `channel` lives: its buffer, its offset within a frame, the frame stride.
    private nonisolated static func sample(in buffers: UnsafeMutableAudioBufferListPointer, channel: Int)
        -> (data: UnsafeMutablePointer<Float>, offset: Int, stride: Int, frames: Int)? {
        var first = 0
        for buffer in buffers {
            let channels = Int(buffer.mNumberChannels)
            if channel < first + channels, let data = buffer.mData?.assumingMemoryBound(to: Float.self) {
                let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * max(1, channels))
                return (data, channel - first, channels, frames)
            }
            first += channels
        }
        return nil
    }

    private static func defaultOutput() -> (id: AudioDeviceID, uid: String)? {
        var address = AppVolumeMixer.address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != 0, let uid = AppVolumeMixer.string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        return (id, uid)
    }

    /// Channels per frame of the tap's sound (a stereo mixdown: 2).
    @available(macOS 14.2, *)
    private static func channelCount(ofTap tap: AudioObjectID) -> Int? {
        var address = AppVolumeMixer.address(kAudioTapPropertyFormat)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format) == noErr, format.mChannelsPerFrame > 0 else { return nil }
        return Int(format.mChannelsPerFrame)
    }

    /// How many input streams a device has (a microphone; built-in speakers have none).
    private static func inputStreamCount(of device: AudioDeviceID) -> Int {
        var address = AppVolumeMixer.address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    /// Marks the aggregate's first `count` input streams (the output device's own, which come
    /// before the tap's) as unused by `procID`: their buffers arrive empty and nothing records.
    private static func switchOff(firstInputStreams count: Int, of device: AudioDeviceID, for procID: AudioDeviceIOProcID) {
        guard count > 0 else { return }
        var address = AppVolumeMixer.address(kAudioDevicePropertyIOProcStreamUsage, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              Int(size) >= MemoryLayout<AudioHardwareIOProcStreamUsage>.size else { return }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: Int(size))
        let usage = raw.bindMemory(to: AudioHardwareIOProcStreamUsage.self, capacity: 1)
        usage.pointee.mIOProc = unsafeBitCast(procID, to: UnsafeMutableRawPointer.self)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr,
              let offset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn) else { return }
        let streams = Int(usage.pointee.mNumberStreams)
        // Keep at least the tap's stream on.
        guard streams > count else { return }
        let isOn = (raw + offset).assumingMemoryBound(to: UInt32.self)
        for index in 0..<count { isOn[index] = 0 }
        if AudioObjectSetPropertyData(device, &address, 0, nil, size, raw) != noErr {
            Log.app.error("App volume: the output's microphone stays in the aggregate")
        }
    }
}

extension AppVolumeMixer {
    /// Recordings: three common players at made-up levels; nothing is tapped.
    func usePreview() {
        apps = [
            AppVolume.App(bundleID: "com.spotify.client", objectIDs: [], isPlaying: true),
            AppVolume.App(bundleID: "com.google.Chrome", objectIDs: [], isPlaying: true),
            AppVolume.App(bundleID: "com.apple.Music", objectIDs: [], isPlaying: false),
        ]
        levels = AppVolume.Levels(values: ["com.google.Chrome": 0.4, "com.apple.Music": 0])
        previewing = true
    }
}
