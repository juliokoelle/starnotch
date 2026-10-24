import Testing
@testable import NotchCore

@Suite struct AudioOutputTests {
    static func cc(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    @Test func kinds() {
        #expect(OutputDevice.kind(transport: Self.cc("bltn"), name: "MacBook Pro Speakers") == .builtIn)
        #expect(OutputDevice.kind(transport: Self.cc("bltn"), name: "External Headphones") == .headphones)
        #expect(OutputDevice.kind(transport: Self.cc("blue"), name: "AirPods Pro") == .bluetooth)
        #expect(OutputDevice.kind(transport: Self.cc("airp"), name: "Living Room") == .airPlay)
        #expect(OutputDevice.kind(transport: Self.cc("virt"), name: "Microsoft Teams Audio") == .virtual)
        #expect(OutputDevice.kind(transport: Self.cc("hdmi"), name: "LG") == .display)
        #expect(OutputDevice.kind(transport: Self.cc("zzzz"), name: "x") == .other)
    }

    @Test func visibleList() {
        let devices = [
            OutputDevice(id: 81, name: "MacBook Pro Microphone", kind: .builtIn, outputStreams: 0),
            OutputDevice(id: 57, name: "Microsoft Teams Audio", kind: .virtual, outputStreams: 1),
            OutputDevice(id: 90, name: "AirPods Pro", kind: .bluetooth, outputStreams: 1),
            OutputDevice(id: 86, name: "MacBook Pro Speakers", kind: .builtIn, outputStreams: 1),
        ]
        #expect(OutputDevice.visible(devices, current: 86).map(\.id) == [86, 90])
        // A virtual device stays visible while it is the output.
        #expect(OutputDevice.visible(devices, current: 57).map(\.id) == [86, 90, 57])
    }
}
