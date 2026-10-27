import AppKit
import CoreAudio
import CoreMediaIO
import IOKit.ps
import IOKit.pwr_mgt
import NotchCore

/// The battery from IOKit's power sources; calls back on every change (no polling).
@MainActor
final class BatteryMonitor {
    private(set) var state: BatteryState?
    var onChange: ((BatteryState?, BatteryState?) -> Void)?
    private var source: CFRunLoopSource?

    func start() {
        state = Self.read()
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let loop = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.update() }
        }, context)?.takeRetainedValue() else { return }
        source = loop
        CFRunLoopAddSource(CFRunLoopGetMain(), loop, .defaultMode)
    }

    private func update() {
        let next = Self.read()
        guard next != state else { return }
        let before = state
        state = next
        onChange?(before, next)
    }

    nonisolated static func read() -> BatteryState? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            if let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
               let state = BatteryState.parse(description) {
                return state
            }
        }
        return nil
    }
}

/// Camera and microphone in use, by any app: CoreMediaIO and CoreAudio say whether a device
/// runs somewhere (no permission needed); for the microphone, the process list names the app.
struct MediaUse: Equatable {
    var camera = false
    var microphone = false
    /// The app using the microphone (also shown for the camera, which has no per-app answer).
    var app: String?

    var inUse: Bool { camera || microphone }

    /// "Camera and mic · FaceTime", for the narrow peek.
    var shortLine: String {
        let what = camera && microphone ? "Camera and mic" : camera ? "Camera" : "Mic"
        return app.map { "\(what) · \($0)" } ?? "\(what) in use"
    }

    /// "Camera and microphone · FaceTime".
    var line: String {
        let what = camera && microphone ? "Camera and microphone" : camera ? "Camera" : "Microphone"
        return app.map { "\(what) · \($0)" } ?? "\(what) in use"
    }

    @MainActor static func read() -> MediaUse {
        var use = MediaUse()
        use.camera = cameraRunning()
        use.microphone = microphoneRunning()
        if use.microphone || use.camera { use.app = microphoneApp() }
        return use
    }

    private static func cameraRunning() -> Bool {
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return false }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size, &size, &devices) == noErr else { return false }
        for device in devices {
            var running: UInt32 = 0
            var length = UInt32(MemoryLayout<UInt32>.size)
            var property = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                                                     mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
                                                     mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
            if CMIOObjectGetPropertyData(device, &property, 0, nil, length, &length, &running) == noErr, running != 0 { return true }
        }
        return false
    }

    private static func microphoneRunning() -> Bool {
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr, device != 0 else { return false }
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr && running != 0
    }

    /// The first app (other than this one) recording from a microphone (macOS 14.2+).
    @MainActor private static func microphoneApp() -> String? {
        guard #available(macOS 14.2, *) else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        for object in objects {
            var input: UInt32 = 0
            var length = UInt32(MemoryLayout<UInt32>.size)
            var property = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                                      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(object, &property, 0, nil, &length, &input) == noErr, input != 0 else { continue }
            var pid: pid_t = 0
            length = UInt32(MemoryLayout<pid_t>.size)
            property.mSelector = kAudioProcessPropertyPID
            guard AudioObjectGetPropertyData(object, &property, 0, nil, &length, &pid) == noErr, pid != me else { continue }
            if let app = AgentsModule.hostApp(of: pid) { return app.localizedName }
        }
        return nil
    }
}

/// "Keep awake": holds the display and the Mac awake until switched off.
@MainActor
final class KeepAwake {
    private var assertion: IOPMAssertionID = 0
    private(set) var isOn = false
    var onChange: ((Bool) -> Void)?

    func toggle() { set(!isOn) }

    func set(_ on: Bool) {
        guard on != isOn else { return }
        if on {
            let reason = "\(Brand.displayName): keep awake" as CFString
            isOn = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                               IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &assertion) == kIOReturnSuccess
        } else {
            IOPMAssertionRelease(assertion)
            assertion = 0
            isOn = false
        }
        onChange?(isOn)
    }
}

/// Dark mode for the whole Mac. Switched through System Events (macOS asks once whether this
/// app may control it), in a separate `osascript` so the island never waits on it.
@MainActor
enum DarkMode {
    static var isOn: Bool {
        CFPreferencesCopyValue("AppleInterfaceStyle" as CFString, kCFPreferencesAnyApplication,
                               kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String == "Dark"
    }

    /// Calls back on the main actor with the state the Mac ended up in.
    static func set(_ dark: Bool, done: @escaping @MainActor @Sendable (Bool) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application \"System Events\" to tell appearance preferences to set dark mode to \(dark)"]
        process.terminationHandler = { _ in Task { @MainActor in done(isOn) } }
        do { try process.run() } catch { done(isOn) }
    }
}

/// The icons on the desktop: Finder's own `CreateDesktop` setting. Finder reads it at launch, so
/// it restarts to apply it (as it does after `defaults write` in Terminal); it comes back by itself.
@MainActor
enum DesktopIcons {
    private static let finder = "com.apple.finder" as CFString
    private static let key = "CreateDesktop" as CFString

    static var hidden: Bool {
        CFPreferencesAppSynchronize(finder)
        let value = CFPreferencesCopyAppValue(key, finder)
        if let flag = value as? Bool { return !flag }
        if let text = value as? String { return ["0", "false", "no"].contains(text.lowercased()) }
        return false
    }

    static func set(hidden: Bool) {
        // Showing them again removes the setting: Finder's default is icons on the desktop.
        CFPreferencesSetAppValue(key, hidden ? kCFBooleanFalse : nil, finder)
        CFPreferencesAppSynchronize(finder)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Finder"]
        try? process.run()
    }
}

/// Long terminal commands from the zsh snippet (see `ShellActivity`): what runs for 30 s or more,
/// and what just finished. Reads one small folder every 5 s, only once the snippet is set up.
@MainActor
final class ShellMonitor {
    private(set) var running: [ShellActivity.Running] = []
    var onChange: (([ShellActivity.Running]) -> Void)?
    var onFinished: ((ShellActivity.Finished) -> Void)?
    private var task: Task<Void, Never>?
    let folder: URL

    init(folder: URL) { self.folder = folder }

    func start() {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.scan()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func scan() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return }
        let now = Date()
        var next: [ShellActivity.Running] = []
        for name in names {
            let url = folder.appending(path: name)
            if name.hasPrefix("done-") {
                if let text = try? String(contentsOf: url, encoding: .utf8), let done = ShellActivity.finished(text: text),
                   now.timeIntervalSince(done.end) < 120 {
                    onFinished?(done)
                }
                try? fm.removeItem(at: url)
            } else if name.hasPrefix("run-"), let text = try? String(contentsOf: url, encoding: .utf8),
                      let run = ShellActivity.running(file: name, text: text) {
                if ClaudeCodeProvider.isAlive(run.pid) {
                    if now.timeIntervalSince(run.start) >= Double(ShellActivity.threshold) { next.append(run) }
                } else {
                    try? fm.removeItem(at: url)  // the shell is gone
                }
            }
        }
        next.sort { $0.start < $1.start }
        if next != running {
            running = next
            onChange?(next)
        }
    }
}
