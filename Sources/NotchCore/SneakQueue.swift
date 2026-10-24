/// Short events the closed island shows as one line for a few seconds ("notes is done",
/// "Standup in 5 min", a status from the local API). One at a time, in order; an event with
/// the same key as a waiting one replaces it, so a chatty source can't flood the notch.
public struct SneakQueue<Item: Sendable>: Sendable {
    public struct Entry: Sendable {
        public var key: String
        public var item: Item
    }

    public private(set) var entries: [Entry] = []
    public let capacity: Int

    public init(capacity: Int = 4) {
        self.capacity = capacity
    }

    public var isEmpty: Bool { entries.isEmpty }

    public mutating func push(_ item: Item, key: String) {
        if let index = entries.firstIndex(where: { $0.key == key }) {
            entries[index].item = item
            return
        }
        entries.append(Entry(key: key, item: item))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    public mutating func pop() -> Entry? {
        entries.isEmpty ? nil : entries.removeFirst()
    }
}
