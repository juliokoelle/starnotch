import NotchCore
import Observation
import SwiftUI

/// The accent of Tara's windows (the Dashboard; the memory map can follow): the colour the user
/// picked for her main character, Nova's blue by default. It is computed from the live settings,
/// so a view that reads `TaraAccent.current` in its body updates when the colour changes.
@MainActor
@Observable
final class TaraAccent {
    static let shared = TaraAccent()

    /// Set once at launch; without it (tests, previews of single views) the base tint of the
    /// first character pack, else the notch's blue.
    @ObservationIgnored weak var cast: AvatarCast?

    /// The accent now, as 0xRRGGBB.
    var hex: UInt32 {
        let library = AvatarLibrary.shared
        let id = cast?.main ?? library.characters.first?.id ?? ""
        guard let raw = library.character(id)?.tint.dropFirst(), let base = UInt32(raw, radix: 16) else { return 0x4C8DFF }
        // Characters that keep their own colours keep their own tint.
        guard let cast, cast.isTintable(id) else { return base }
        let colorway = cast.colorway
        return AccentTint.hex(base: base, hue: colorway.hue, saturation: colorway.saturation,
                              tint: colorway.tintAmount > 0 ? colorway.tint : nil)
    }

    var color: Color { Color(hex: hex) }

    /// Light enough that text on it should be dark (relative luminance over 0.4).
    var isLight: Bool {
        let value = hex
        func linear(_ shift: UInt32) -> Double {
            let c = Double((value >> shift) & 0xFF) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(16) + 0.7152 * linear(8) + 0.0722 * linear(0) > 0.4
    }

    /// Shorthand for views: reads (and so observes) the shared accent.
    static var current: Color { shared.color }
}
