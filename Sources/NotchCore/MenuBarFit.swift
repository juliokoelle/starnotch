import CoreGraphics

/// Where the open island may end beside the notch without cutting a menu bar icon in half.
/// The island is centred on the notch, so one width places both edges; each has to sit in a gap
/// between the icons on its side.
public enum MenuBarFit {
    /// How far an edge reaches past an icon it covers.
    public static let margin: CGFloat = 4

    /// The width closest to `preferred` within `range` at which every icon is covered fully (plus
    /// `margin`) or not at all. Icons whose frames touch or overlap by less than `margin` (an
    /// item's frame includes its own padding) are split at the seam between them. Without items,
    /// or when no width in `range` fits, `preferred`. On a tie the narrower width wins.
    ///
    /// - Parameter items: horizontal extents of the icons relative to the notch centre, negative
    ///   to the left of it.
    public static func width(preferred: CGFloat, in range: ClosedRange<CGFloat>, items: [ClosedRange<CGFloat>]) -> CGFloat {
        guard !items.isEmpty else { return preferred }
        // Everything in distances from the centre: an edge at `d` is the half width.
        let right = edges(items.filter { $0.lowerBound + $0.upperBound >= 0 })
        let left = edges(items.filter { $0.lowerBound + $0.upperBound < 0 }.map { -$0.upperBound ... -$0.lowerBound })
        let low = range.lowerBound / 2, high = range.upperBound / 2
        let target = min(max(preferred / 2, low), high)
        func fits(_ d: CGFloat) -> Bool {
            low <= d && d <= high && right.contains { $0.contains(d) } && left.contains { $0.contains(d) }
        }
        // The best fit is the target itself or where an allowed stretch (or the range) ends.
        let candidates = [target, low, high] + (right + left).flatMap { [$0.lowerBound, $0.upperBound] }
        let best = candidates.filter(fits).min { a, b in
            let da = abs(a - target), db = abs(b - target)
            return da < db || (da == db && a < b)
        }
        return best.map { $0 * 2 } ?? preferred
    }

    /// Distances from the centre at which an edge cuts none of `spans` (all on one side).
    static func edges(_ spans: [ClosedRange<CGFloat>]) -> [ClosedRange<CGFloat>] {
        guard !spans.isEmpty else { return [0 ... .infinity] }
        // Frames overlapping by more than the margin leave no gap between them: one block.
        var blocks: [ClosedRange<CGFloat>] = []
        for span in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = blocks.last, span.lowerBound < last.upperBound - margin {
                blocks[blocks.count - 1] = last.lowerBound ... max(last.upperBound, span.upperBound)
            } else {
                blocks.append(span)
            }
        }
        var allowed: [ClosedRange<CGFloat>] = []
        if blocks[0].lowerBound >= 0 { allowed.append(0 ... blocks[0].lowerBound) }
        for (block, next) in zip(blocks, blocks.dropFirst()) {
            if next.lowerBound - block.upperBound >= margin {
                allowed.append(block.upperBound + margin ... next.lowerBound)
            } else {
                let seam = (block.upperBound + next.lowerBound) / 2
                allowed.append(seam ... seam)
            }
        }
        allowed.append(blocks[blocks.count - 1].upperBound + margin ... .infinity)
        return allowed
    }
}

extension MenuBarFit {
    /// How far the closed island may reach out beside the notch, per side, without covering a menu
    /// bar icon: `limit` (the configured room) or less where an icon sits closer to the notch on
    /// either side (the island is centred, so the tighter side decides). Icons that overlap the
    /// notch itself are ignored: macOS hides those behind the camera housing. Less than `minimum`
    /// left is no room at all, so a sliver of an ear never shows.
    ///
    /// - Parameters:
    ///   - halfNotch: half the notch width.
    ///   - items: horizontal extents of the icons relative to the notch centre, negative left of it.
    public static func earRoom(halfNotch: CGFloat, limit: CGFloat, items: [ClosedRange<CGFloat>], minimum: CGFloat = 0) -> CGFloat {
        var room = limit
        for item in items {
            if item.lowerBound >= halfNotch {
                room = min(room, item.lowerBound - halfNotch - margin)
            } else if item.upperBound <= -halfNotch {
                room = min(room, -halfNotch - item.upperBound - margin)
            }
        }
        return room < minimum ? 0 : max(0, room)
    }
}
