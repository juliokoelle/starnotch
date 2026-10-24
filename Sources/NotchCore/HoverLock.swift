/// Keeps the island open while something it owns is showing outside the shape (Apple's AirPlay
/// picker, a menu). Each holder gets a token; the island may collapse again when all tokens are
/// released. Releasing twice or an unknown token does nothing.
public struct HoverLock: Sendable {
    private var holders: [Int: String] = [:]
    private var next = 0

    public init() {}

    public var isLocked: Bool { !holders.isEmpty }
    public var reasons: [String] { holders.keys.sorted().compactMap { holders[$0] } }

    public mutating func acquire(_ reason: String) -> Int {
        next += 1
        holders[next] = reason
        return next
    }

    /// - Returns: `true` when this release unlocked the island.
    @discardableResult
    public mutating func release(_ token: Int) -> Bool {
        guard holders.removeValue(forKey: token) != nil else { return false }
        return holders.isEmpty
    }
}
