import Testing
import TestSupport
@testable import NotchCore

@Suite struct DeviceBatteriesTests {
    let profiler = """
    {"SPBluetoothDataType":[{"controller_properties":{},"device_connected":[
      {"Max’s Magic Mouse":{"device_address":"A4:83:E7:12:34:56","device_batteryLevelMain":"64%","device_minorType":"Mouse"}},
      {"Max’s AirPods Pro":{"device_address":"10:20:30:40:50:60","device_batteryLevelLeft":"80%","device_batteryLevelRight":"78%","device_batteryLevelCase":"52%","device_minorType":"Headphones"}},
      {"Desk Speaker":{"device_address":"AA:BB:CC:DD:EE:FF","device_minorType":"Speaker"}}
    ],"device_not_connected":[{"Old Keyboard":{"device_batteryLevelMain":"10%"}}]}]}
    """

    @Test func connectedDevicesWithALevelAndTheirKind() {
        let devices = DeviceBattery.connected(Bytes.data(profiler))
        #expect(devices.map(\.name) == ["Max’s Magic Mouse", "Max’s AirPods Pro"])
        #expect(devices.map(\.kind) == [.mouse, .headphones])
        #expect(devices.first?.address == "a4:83:e7:12:34:56")
        #expect(DeviceBattery.connected(Bytes.data("{}")).isEmpty)
        // The AirPods line for the audio output reads the same list.
        #expect(DeviceBattery.parse(Bytes.data(profiler), preferring: "AirPods Pro")?.line == "L 80 % · R 78 % · Case 52 %")
    }

    @Test func kindsFromNameAndMinorType() {
        #expect(DeviceBattery.kind(name: "Magic Trackpad", minorType: "Mouse") == .trackpad)
        #expect(DeviceBattery.kind(name: "Magic Keyboard with Touch ID", minorType: nil) == .keyboard)
        #expect(DeviceBattery.kind(name: "Beats Studio 3", minorType: nil) == .headphones)
        #expect(DeviceBattery.kind(name: "Xbox Wireless Controller", minorType: "Gamepad") == .gamepad)
        #expect(DeviceBattery.kind(name: "Pen", minorType: nil) == .other)
    }

    @Test func addressesFromBothSourcesMatch() {
        #expect(DeviceBattery.normalizedAddress("a4-83-e7-12-34-56") == "a4:83:e7:12:34:56")
        #expect(DeviceBattery.normalizedAddress("A4:83:E7:12:34:56") == "a4:83:e7:12:34:56")
        #expect(DeviceBattery.normalizedAddress("FIFO") == nil)
        #expect(DeviceBattery.normalizedAddress(nil) == nil)
    }

    @Test func hidServicesWithAPercentage() {
        let mouse = DeviceBattery.hid(["Product": "Magic Mouse", "BatteryPercent": 61, "DeviceAddress": "a4-83-e7-12-34-56"])
        #expect(mouse == DeviceBattery(name: "Magic Mouse", main: 61, kind: .mouse, address: "a4:83:e7:12:34:56"))
        // The built-in keyboard and trackpad report no level.
        #expect(DeviceBattery.hid(["Product": "Apple Internal Keyboard / Trackpad", "Transport": "FIFO"]) == nil)
        #expect(DeviceBattery.hid(["BatteryPercent": 40]) == nil)
    }

    @Test func oneDeviceFromTwoSourcesShowsOnce() throws {
        let bluetooth = DeviceBattery.connected(Bytes.data(profiler))
        let hid = [DeviceBattery(name: "Magic Mouse", main: 61, kind: .mouse, address: "a4:83:e7:12:34:56"),
                   DeviceBattery(name: "Magic Keyboard", main: 12, kind: .keyboard),
                   DeviceBattery(name: "Magic Keyboard", main: 12, kind: .keyboard)]
        let merged = DeviceBattery.merged(hid: hid, bluetooth: bluetooth)
        #expect(merged.map(\.name) == ["Magic Keyboard", "Max’s AirPods Pro", "Max’s Magic Mouse"])
        let mouse = try #require(merged.last)
        #expect(mouse.main == 61)
        // The earbuds keep their own levels.
        #expect(merged[1].line == "L 80 % · R 78 % · Case 52 %")
    }

    @Test func lowBatteryOncePerCharge() {
        var alerts = DeviceBatteryAlerts()
        let mouse = { (level: Int) in DeviceBattery(name: "Magic Mouse", main: level, kind: .mouse, address: "a4:83:e7:12:34:56") }
        #expect(alerts.update([mouse(40)]).isEmpty)
        #expect(alerts.update([mouse(14)]).map(\.name) == ["Magic Mouse"])
        #expect(alerts.update([mouse(9)]).isEmpty)
        // Gone and back, still low: no second line.
        #expect(alerts.update([]).isEmpty)
        #expect(alerts.update([mouse(8)]).isEmpty)
        // 15 to 19 % is not charged yet.
        #expect(alerts.update([mouse(17)]).isEmpty)
        #expect(alerts.update([mouse(13)]).isEmpty)
        // Charged: the next drop warns again.
        #expect(alerts.update([mouse(85)]).isEmpty)
        #expect(alerts.update([mouse(12)]).count == 1)
    }

    @Test func earbudsWarnByTheLowerOneNotTheCase() {
        var alerts = DeviceBatteryAlerts()
        #expect(alerts.update([DeviceBattery(name: "AirPods", left: 60, right: 58, caseLevel: 5, kind: .headphones)]).isEmpty)
        #expect(alerts.update([DeviceBattery(name: "AirPods", left: 60, right: 11, caseLevel: 5, kind: .headphones)]).count == 1)
    }
}
