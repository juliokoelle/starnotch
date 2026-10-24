import Testing
@testable import NotchCore

@Suite struct SwipeTests {
    func run(_ deltas: [(Double, Double)], natural: Bool = true) -> [SwipeClassifier.Swipe] {
        var classifier = SwipeClassifier()
        var out: [SwipeClassifier.Swipe] = []
        _ = classifier.feed(deltaX: 0, deltaY: 0, natural: natural, phase: .began, momentum: false)
        for (x, y) in deltas {
            if let swipe = classifier.feed(deltaX: x, deltaY: y, natural: natural, phase: .changed, momentum: false) { out.append(swipe) }
        }
        _ = classifier.feed(deltaX: 0, deltaY: 0, natural: natural, phase: .ended, momentum: false)
        return out
    }

    @Test func downAndUpOncePerGesture() {
        #expect(run(Array(repeating: (0, 6), count: 12)) == [.down])
        #expect(run(Array(repeating: (0.5, -8), count: 10)) == [.up])
    }

    @Test func traditionalScrollingIsFlipped() {
        #expect(run(Array(repeating: (0, -6), count: 10), natural: false) == [.down])
    }

    @Test func sideways() {
        #expect(run(Array(repeating: (7, 1), count: 6)) == [.right])
        #expect(run(Array(repeating: (-7, -1), count: 6)) == [.left])
    }

    @Test func diagonalAndSmallMovesDoNothing() {
        #expect(run(Array(repeating: (5, 5), count: 10)).isEmpty)
        #expect(run([(0, 4), (0, 4), (0, 4)]).isEmpty)
    }

    @Test func momentumIsIgnored() {
        var classifier = SwipeClassifier()
        _ = classifier.feed(deltaX: 0, deltaY: 0, natural: true, phase: .began, momentum: false)
        #expect(classifier.feed(deltaX: 0, deltaY: 80, natural: true, phase: .changed, momentum: true) == nil)
    }
}
