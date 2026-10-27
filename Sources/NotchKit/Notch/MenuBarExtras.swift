import AppKit
import ApplicationServices

/// Where the menu bar extras (the status icons of every app and of macOS) sit, so the open island
/// can end between two of them (`MenuBarFit`). There's no public API for this; the Accessibility
/// tree has them as each app's `AXExtrasMenuBar`. Read off the main thread and cached: every app
/// at launch, when an app starts or quits and at most once a minute on open, otherwise only the
/// apps known to have extras (about 10 ms). Nothing polls. Without Accessibility permission the
/// list stays empty and the island keeps its own widths.
@MainActor
final class MenuBarExtras {
    /// The icons' frames in global AppKit coordinates.
    private(set) var frames: [CGRect] = []
    /// After each read that changed `frames`.
    var onChange: (() -> Void)?

    /// Apps that had extras at the last full read.
    private var owners: [pid_t] = []
    private var lastFullRead = Date.distantPast
    private var reading = false
    /// A refresh asked for while one was running (`true` = a full one).
    private var queued: Bool?
    private var launchTask: Task<Void, Never>?

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appsChanged() }
            }
        }
    }

    /// Re-reads the frames: every app when `full` or a minute after the last full read, else only
    /// the apps that had extras then.
    func refresh(full: Bool = false) {
        guard AXIsProcessTrusted() else {
            Log.app.debug("Menu bar: no Accessibility permission, the island keeps its widths")
            if !frames.isEmpty { frames = []; onChange?() }
            return
        }
        let full = full || owners.isEmpty || Date().timeIntervalSince(lastFullRead) > 60
        guard !reading else {
            queued = (queued ?? false) || full
            return
        }
        reading = true
        let pids = full ? NSWorkspace.shared.runningApplications.map(\.processIdentifier) : owners
        // Accessibility positions count from the top left of the primary display.
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        Task {
            // On a dispatch queue: the read blocks while apps answer, which the task pool shouldn't.
            let found = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: Self.read(pids, primaryTop: primaryTop))
                }
            }
            self.reading = false
            if full {
                self.owners = found.map(\.pid)
                self.lastFullRead = Date()
            }
            let frames = found.flatMap(\.frames).sorted { $0.minX < $1.minX }
            Log.app.debug("Menu bar: \(frames.count) icons from \(found.count) of \(pids.count) apps")
            if frames != self.frames {
                self.frames = frames
                self.onChange?()
            }
            if let again = self.queued {
                self.queued = nil
                self.refresh(full: again)
            }
        }
    }

    /// A new app puts up its icon a moment after it starts.
    private func appsChanged() {
        launchTask?.cancel()
        launchTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.refresh(full: true)
        }
    }

    private struct Found: Sendable {
        var pid: pid_t
        var frames: [CGRect]
    }

    /// Asks each app for its extras, in parallel; an app that doesn't answer within 0.1 s is skipped.
    nonisolated private static func read(_ pids: [pid_t], primaryTop: CGFloat) -> [Found] {
        final class Results: @unchecked Sendable {
            let lock = NSLock()
            var found: [Found] = []
        }
        let results = Results()
        DispatchQueue.concurrentPerform(iterations: pids.count) { index in
            let app = AXUIElementCreateApplication(pids[index])
            AXUIElementSetMessagingTimeout(app, 0.1)
            guard let bar = copy(app, "AXExtrasMenuBar"), CFGetTypeID(bar) == AXUIElementGetTypeID(),
                  let items = copy(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement] else { return }
            let frames = items.compactMap { item -> CGRect? in
                guard let position = copy(item, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
                      let size = copy(item, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
                var origin = CGPoint.zero, extent = CGSize.zero
                guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent),
                      extent.width > 0, extent.height > 0 else { return nil }
                return CGRect(x: origin.x, y: primaryTop - origin.y - extent.height, width: extent.width, height: extent.height)
            }
            results.lock.lock()
            results.found.append(Found(pid: pids[index], frames: frames))
            results.lock.unlock()
        }
        return results.found
    }

    nonisolated private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }
}
