/// What has to happen when the user picks a slot: which apps to quit, which one to start.
public struct SwitchPlan: Equatable, Sendable {
    public var launch: String
    public var terminate: [String]

    public init(launch: String, terminate: [String]) {
        self.launch = launch
        self.terminate = terminate
    }

    /// - Parameters:
    ///   - slots: Bundle identifiers per slot (`nil` = empty slot), indexed by `SlotPosition.rawValue`.
    ///   - selected: The chosen slot.
    ///   - running: Bundle identifiers of currently running apps.
    /// - Returns: `nil` if the selected slot is empty.
    public static func make(slots: [String?], selected: SlotPosition, running: Set<String>) -> SwitchPlan? {
        guard slots.indices.contains(selected.rawValue), let target = slots[selected.rawValue] else {
            return nil
        }
        var terminate: [String] = []
        for case let bundleID? in slots where bundleID != target {
            if running.contains(bundleID), !terminate.contains(bundleID) {
                terminate.append(bundleID)
            }
        }
        return SwitchPlan(launch: target, terminate: terminate)
    }
}
