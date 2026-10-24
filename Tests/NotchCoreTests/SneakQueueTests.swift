import Testing
@testable import NotchCore

@Suite struct SneakQueueTests {
    @Test func firstInFirstOut() {
        var queue = SneakQueue<String>()
        queue.push("a", key: "1")
        queue.push("b", key: "2")
        #expect(queue.pop()?.item == "a")
        #expect(queue.pop()?.item == "b")
        #expect(queue.pop() == nil)
    }

    @Test func sameKeyReplacesInPlace() {
        var queue = SneakQueue<String>()
        queue.push("build 10 %", key: "ci")
        queue.push("other", key: "x")
        queue.push("build 90 %", key: "ci")
        #expect(queue.entries.map(\.item) == ["build 90 %", "other"])
    }

    @Test func capacityDropsOldest() {
        var queue = SneakQueue<Int>(capacity: 2)
        for i in 1...4 { queue.push(i, key: "\(i)") }
        #expect(queue.entries.map(\.item) == [3, 4])
    }
}
