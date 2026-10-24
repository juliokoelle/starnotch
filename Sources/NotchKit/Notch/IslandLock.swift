import NotchCore

/// The island's hover lock (see `HoverLock`), shared by everything that opens UI outside the
/// island's shape or floats over it. The controller doesn't collapse while it's held.
@MainActor
final class IslandLock {
    static let shared = IslandLock()

    private var lock = HoverLock()
    /// Holders that a click outside the island may close (our own output list). Apple's AirPlay
    /// picker has none: clicks into it land "outside" too.
    private var dismissers: [Int: () -> Void] = [:]
    var onUnlock: (() -> Void)?

    var isLocked: Bool { lock.isLocked }

    func acquire(_ reason: String, dismiss: (() -> Void)? = nil) -> Int {
        Log.app.debug("Island locked: \(reason, privacy: .public)")
        let token = lock.acquire(reason)
        if let dismiss { dismissers[token] = dismiss }
        return token
    }

    func release(_ token: Int) {
        dismissers[token] = nil
        if lock.release(token) { onUnlock?() }
    }

    /// A click outside the island closes what may be closed, but only when nothing else (a
    /// system picker) holds the lock. The handlers release their own tokens.
    func dismissOnOutsideClick() {
        guard !dismissers.isEmpty, dismissers.count == lock.reasons.count else { return }
        for dismiss in dismissers.values { dismiss() }
    }
}
