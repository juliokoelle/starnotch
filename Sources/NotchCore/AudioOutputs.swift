/// An audio output as CoreAudio reports it, reduced to what the notch's output list needs.
public struct OutputDevice: Equatable, Sendable, Identifiable {
    public enum Kind: Int, Comparable, Sendable {
        case builtIn, headphones, bluetooth, airPlay, usb, display, other, virtual

        public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }

        public var symbol: String {
            switch self {
            case .builtIn: "laptopcomputer"
            case .headphones: "headphones"
            case .bluetooth: "airpodspro"
            case .airPlay: "airplayaudio"
            case .usb: "cable.connector"
            case .display: "display"
            case .other, .virtual: "speaker.wave.2"
            }
        }
    }

    public var id: UInt32
    public var name: String
    public var kind: Kind
    public var outputStreams: Int

    public init(id: UInt32, name: String, kind: Kind, outputStreams: Int) {
        self.id = id
        self.name = name
        self.kind = kind
        self.outputStreams = outputStreams
    }

    /// From CoreAudio's four-character transport type (`kAudioDevicePropertyTransportType`) and,
    /// for built-in devices, the name (wired headphones show up as built-in "Headphones").
    public static func kind(transport: UInt32, name: String) -> Kind {
        switch fourCC(transport) {
        case "bltn": name.localizedLowercaseContains("headphone") || name.localizedLowercaseContains("kopfhörer") ? .headphones : .builtIn
        case "blue", "blea": .bluetooth
        case "airp": .airPlay
        case "usb ": .usb
        case "hdmi", "dprt", "thun": .display
        case "virt", "grup", "agrg": .virtual
        default: .other
        }
    }

    static func fourCC(_ value: UInt32) -> String {
        String(decoding: [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)], as: UTF8.self)
    }

    /// The list to show: only devices with output streams; virtual devices (meeting apps,
    /// aggregates) only when they are the current output; built-in first, then by kind and name.
    public static func visible(_ devices: [OutputDevice], current: UInt32?) -> [OutputDevice] {
        devices
            .filter { $0.outputStreams > 0 && ($0.kind != .virtual || $0.id == current) }
            .sorted { ($0.kind, $0.name) < ($1.kind, $1.name) }
    }
}

extension String {
    fileprivate func localizedLowercaseContains(_ text: String) -> Bool { lowercased().contains(text) }
}
