/// Turns two-finger trackpad scrolling over the notch into one swipe per gesture:
/// down opens, up closes, sideways switches the module.
public struct SwipeClassifier: Sendable {
    public enum Swipe: Equatable, Sendable { case up, down, left, right }

    public enum Phase: Sendable {
        case began, changed, ended, other
    }

    /// Finger travel (points) before a swipe counts.
    public var threshold: Double = 26
    /// The dominant axis must lead the other by this factor.
    public var dominance: Double = 1.6

    private var dx = 0.0
    private var dy = 0.0
    private var fired = false

    public init() {}

    /// - Parameters:
    ///   - deltaX, deltaY: `scrollingDeltaX/Y` of the event.
    ///   - natural: `isDirectionInvertedFromDevice` ("natural scrolling"): then deltas follow the
    ///     fingers; otherwise they point the other way.
    ///   - momentum: true for momentum events after the fingers left the trackpad (ignored).
    public mutating func feed(deltaX: Double, deltaY: Double, natural: Bool, phase: Phase, momentum: Bool) -> Swipe? {
        if momentum { return nil }
        switch phase {
        case .began:
            dx = 0; dy = 0; fired = false
        case .ended, .other:
            dx = 0; dy = 0; fired = false
            return nil
        case .changed:
            break
        }
        guard !fired else { return nil }
        let sign = natural ? 1.0 : -1.0
        dx += deltaX * sign
        dy += deltaY * sign
        let ax = abs(dx), ay = abs(dy)
        if ay >= threshold, ay >= ax * dominance {
            fired = true
            return dy > 0 ? .down : .up
        }
        if ax >= threshold, ax >= ay * dominance {
            fired = true
            // Fingers moving left reveal the module on the right, like paging.
            return dx > 0 ? .right : .left
        }
        return nil
    }
}
