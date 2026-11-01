import Foundation
import IOKit
import NotchCore

/// The battery of every connected device, for the System tab: IOKit's HID battery services (Magic
/// Mouse, Keyboard and Trackpad, and any HID device that reports `BatteryPercent`) and Bluetooth's
/// list from `system_profiler` (AirPods with each earbud and the case, as for the audio output),
/// read together off the main thread. Every five minutes, a few seconds after a HID device comes
/// or goes, and when the System panel opens on a read older than a minute. No Bluetooth
/// permission is needed; nothing is read while the switch is off.
@MainActor
final class DeviceBatteryMonitor {
    var onChange: (([DeviceBattery]) -> Void)?
    /// A device fell below 15 %: once per device and charge (`DeviceBatteryAlerts`).
    var onLow: ((DeviceBattery) -> Void)?
    private(set) var devices: [DeviceBattery] = []
    private var alerts = DeviceBatteryAlerts()
    private var timer: Task<Void, Never>?
    private var connectRead: Task<Void, Never>?
    private var reading = false
    private var lastRead = Date.distantPast
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []

    static let interval: Duration = .seconds(300)
    nonisolated static let service = "AppleDeviceManagementHIDEventService"

    func start() {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                self?.read()
                try? await Task.sleep(for: Self.interval)
            }
        }
        watchConnections()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        connectRead?.cancel()
        connectRead = nil
        iterators.forEach { IOObjectRelease($0) }
        iterators = []
        if let port { IONotificationPortDestroy(port) }
        port = nil
        if !devices.isEmpty {
            devices = []
            onChange?([])
        }
    }

    /// The System panel opened: fresh levels unless the last read is recent.
    func refreshIfStale() {
        guard timer != nil, Date().timeIntervalSince(lastRead) > 60 else { return }
        read()
    }

    private func read() {
        guard !reading else { return }
        reading = true
        Task { [weak self] in
            let found = await Task.detached(priority: .utility) {
                DeviceBattery.merged(hid: Self.hidDevices(), bluetooth: HeadphoneBattery.profile().map(DeviceBattery.connected) ?? [])
            }.value
            guard let self else { return }
            self.reading = false
            // Switched off meanwhile: nothing to show or say.
            guard self.timer != nil else { return }
            self.lastRead = Date()
            if found != self.devices {
                self.devices = found
                self.onChange?(found)
            }
            for device in self.alerts.update(found) { self.onLow?(device) }
        }
    }

    /// The HID battery services, three properties each.
    private nonisolated static func hidDevices() -> [DeviceBattery] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(service), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var found: [DeviceBattery] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var properties: [String: Any] = [:]
            for key in ["Product", "BatteryPercent", "DeviceAddress"] {
                properties[key] = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            if let device = DeviceBattery.hid(properties) { found.append(device) }
        }
        return found
    }

    /// A HID device came or went: read once its battery has reported (a few seconds after it
    /// connects).
    private func watchConnections() {
        guard port == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        IONotificationPortSetDispatchQueue(port, .main)
        let callback: IOServiceMatchingCallback = { context, iterator in
            // Draining the iterator arms the next notification.
            while case let entry = IOIteratorNext(iterator), entry != 0 { IOObjectRelease(entry) }
            guard let context else { return }
            let monitor = Unmanaged<DeviceBatteryMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.connectionChanged() }
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            guard IOServiceAddMatchingNotification(port, type, IOServiceMatching(Self.service), callback, context, &iterator) == KERN_SUCCESS else { continue }
            // The devices already there are in the first read.
            while case let entry = IOIteratorNext(iterator), entry != 0 { IOObjectRelease(entry) }
            iterators.append(iterator)
        }
    }

    private func connectionChanged() {
        connectRead?.cancel()
        connectRead = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.read()
        }
    }
}

extension DeviceBattery {
    /// The device's symbol in the System tab and its low-battery line.
    var symbol: String {
        switch kind {
        case .mouse: "magicmouse"
        case .keyboard: "keyboard"
        case .trackpad: "rectangle.and.hand.point.up.left"
        case .headphones:
            name.localizedCaseInsensitiveContains("AirPods Pro") ? "airpodspro"
                : name.localizedCaseInsensitiveContains("AirPods Max") ? "airpodsmax"
                : name.localizedCaseInsensitiveContains("AirPods") ? "airpods" : "headphones"
        case .gamepad: "gamecontroller"
        case .speaker: "hifispeaker"
        case .other: "battery.75percent"
        }
    }
}
