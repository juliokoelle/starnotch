import AppKit
import NotchCore

/// Executes a `SwitchPlan`: quits the other slot apps, waits for them, launches the target.
@MainActor
final class AppSwitcher {
    private var task: Task<Void, Never>?

    func perform(_ plan: SwitchPlan, target: SlotApp, forceQuit: Bool, timeout: Double) {
        task?.cancel()
        task = Task { [weak self] in
            await self?.run(plan, target: target, forceQuit: forceQuit, timeout: timeout)
        }
    }

    private func run(_ plan: SwitchPlan, target: SlotApp, forceQuit: Bool, timeout: Double) async {
        let others = plan.terminate.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
        // Read up front: once terminated, an NSRunningApplication no longer reports its bundle.
        let bundlePaths = others.map { $0.bundleURL?.path }
        for app in others {
            Log.switcher.info("Quitting \(app.bundleIdentifier ?? "?", privacy: .public)")
            app.terminate()
        }

        // Wait until the other notch apps are gone so two apps never fight over the notch.
        let deadline = Date().addingTimeInterval(timeout)
        while others.contains(where: { !$0.isTerminated }), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(80))
            if Task.isCancelled { return }
        }

        let stubborn = others.filter { !$0.isTerminated }
        if !stubborn.isEmpty {
            if forceQuit {
                for app in stubborn {
                    Log.switcher.notice("Force quitting \(app.bundleIdentifier ?? "?", privacy: .public)")
                    app.forceTerminate()
                }
            } else {
                Log.switcher.notice("\(stubborn.count) app(s) did not quit within \(timeout) s; force quit is off")
            }
        }

        guard let url = AppIcons.url(for: target) else {
            Log.switcher.error("Cannot find \(target.bundleID, privacy: .public)")
            NSSound.beep()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        Log.switcher.info("Launching \(target.bundleID, privacy: .public)")
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                Log.switcher.error("Launch failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Some notch apps leave helpers behind when they quit. Give well-behaved ones a moment
        // to exit on their own, then stop what's left of the apps that actually quit.
        let quitPaths = zip(others, bundlePaths).compactMap { app, path in app.isTerminated ? path : nil }
        guard !quitPaths.isEmpty else { return }
        try? await Task.sleep(for: .seconds(1.5))
        stopLeftovers(of: quitPaths)
    }

    private func stopLeftovers(of bundlePaths: [String]) {
        let pids = LeftoverProcesses.select(
            ProcessList.snapshot(),
            bundlePaths: bundlePaths,
            excluding: [getpid()]
        )
        for pid in pids {
            Log.switcher.info("Stopping leftover helper \(pid) of \(bundlePaths.joined(separator: ", "), privacy: .public)")
            kill(pid, SIGTERM)
        }
    }
}
