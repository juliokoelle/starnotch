import Foundation

// The battery of every connected device for the System tab: Bluetooth devices from
// `system_profiler` (AirPods with each earbud and the case), Magic Mouse, Keyboard and Trackpad
// and other HID devices from IOKit's `BatteryPercent`, merged into one list.

extension DeviceBattery {
    public enum Kind: String, Sendable { case mouse, keyboard, trackpad, headphones, gamepad, speaker, other }

    /// What a device is, from its name and Bluetooth's minor type ("Mouse", "Headphones").
    public static func kind(name: String, minorType: String?) -> Kind {
        let text = "\(name) \(minorType ?? "")".lowercased()
        if text.contains("trackpad") { return .trackpad }
        if text.contains("mouse") { return .mouse }
        if text.contains("keyboard") { return .keyboard }
        if ["airpods", "beats", "headphone", "headset", "buds"].contains(where: text.contains) { return .headphones }
        if ["gamepad", "controller", "joystick"].contains(where: text.contains) { return .gamepad }
        if text.contains("speaker") { return .speaker }
        return .other
    }

    /// "A4-83-E7-12-34-56" (IOKit) and "A4:83:E7:12:34:56" (system_profiler) as "a4:83:e7:12:34:56".
    public static func normalizedAddress(_ raw: String?) -> String? {
        let hex = (raw ?? "").lowercased().filter(\.isHexDigit)
        guard hex.count == 12 else { return nil }
        return stride(from: 0, to: 12, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return String(hex[start..<hex.index(start, offsetBy: 2)])
        }.joined(separator: ":")
    }

    /// A device from the properties of an `AppleDeviceManagementHIDEventService`; nil without a
    /// level (the built-in keyboard and trackpad have none).
    public static func hid(_ properties: [String: Any]) -> DeviceBattery? {
        guard let percent = properties["BatteryPercent"] as? Int, (0...100).contains(percent) else { return nil }
        let name = (properties["Product"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !name.isEmpty else { return nil }
        return DeviceBattery(name: name, main: percent, kind: kind(name: name, minorType: nil),
                             address: normalizedAddress(properties["DeviceAddress"] as? String))
    }

    /// Who it is for the low-battery line: its address, else its name.
    public var key: String { address ?? name }

    /// One list from both sources, by name. A device in both (the same address, or the same name
    /// where one has no address) shows once, with the name the user gave it and IOKit's level.
    public static func merged(hid: [DeviceBattery], bluetooth: [DeviceBattery]) -> [DeviceBattery] {
        func same(_ a: DeviceBattery, _ b: DeviceBattery) -> Bool {
            if let x = a.address, let y = b.address { return x == y }
            return !a.name.isEmpty && !b.name.isEmpty && sameDevice(a.name, b.name)
        }
        var result = bluetooth
        for device in hid {
            guard let index = result.firstIndex(where: { same($0, device) }) else {
                result.append(device)
                continue
            }
            if let main = device.main, result[index].left == nil && result[index].right == nil { result[index].main = main }
            if result[index].kind == .other { result[index].kind = device.kind }
            if result[index].address == nil { result[index].address = device.address }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// A line when a device's battery falls below 15 %, once per charge: the same device is named
/// again only after it was back at 20 % or more.
public struct DeviceBatteryAlerts: Sendable {
    public static let low = 15
    public static let recharged = 20

    private var warned: Set<String> = []

    public init() {}

    /// The devices to warn about now.
    public mutating func update(_ devices: [DeviceBattery]) -> [DeviceBattery] {
        var due: [DeviceBattery] = []
        for device in devices {
            guard let level = device.lowest else { continue }
            if level < Self.low {
                if warned.insert(device.key).inserted { due.append(device) }
            } else if level >= Self.recharged {
                warned.remove(device.key)
            }
        }
        return due
    }
}
