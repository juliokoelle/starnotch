import Foundation

/// The interface's accent from Tara's colour: the colour the user picked for her (a colorway)
/// applied to her own tint (Nova's blue by default). Pure arithmetic in 0xRRGGBB.
public enum AccentTint {
    /// A colorway with its own tint (Mint, Cosmo, Rosé, …) gives that tint; a hue shift turns
    /// the base tint as it turns her sprites; a colourless one (White, Chrome, Matte Black)
    /// keeps the base tint, since a grey accent can't mark anything.
    public static func hex(base: UInt32, hue: Double = 0, saturation: Double = 1, tint: UInt32? = nil) -> UInt32 {
        if let tint { return tint }
        guard saturation >= 0.5, hue != 0 || saturation != 1 else { return base }
        var (h, s, b) = hsb(base)
        h = (h + hue / 360).truncatingRemainder(dividingBy: 1)
        if h < 0 { h += 1 }
        s = min(1, s * min(saturation, 1.3))
        return rgb(h, s, b)
    }

    static func hsb(_ value: UInt32) -> (Double, Double, Double) {
        let r = Double((value >> 16) & 0xFF) / 255, g = Double((value >> 8) & 0xFF) / 255, b = Double(value & 0xFF) / 255
        let high = max(r, g, b), low = min(r, g, b), range = high - low
        var h = 0.0
        if range > 0 {
            if high == r { h = ((g - b) / range).truncatingRemainder(dividingBy: 6) }
            else if high == g { h = (b - r) / range + 2 }
            else { h = (r - g) / range + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, high == 0 ? 0 : range / high, high)
    }

    static func rgb(_ h: Double, _ s: Double, _ v: Double) -> UInt32 {
        let sector = h * 6, i = Int(sector) % 6, f = sector - Double(Int(sector))
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        let (r, g, b): (Double, Double, Double) = switch i {
        case 0: (v, t, p)
        case 1: (q, v, p)
        case 2: (p, v, t)
        case 3: (p, q, v)
        case 4: (t, p, v)
        default: (v, p, q)
        }
        func byte(_ x: Double) -> UInt32 { UInt32(max(0, min(255, (x * 255).rounded()))) }
        return byte(r) << 16 | byte(g) << 8 | byte(b)
    }
}
