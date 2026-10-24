import Darwin
import Foundation
import NotchCore

/// What the agent tracker shows. Built off the main thread by `AgentScanner`.
struct AgentSnapshot: Equatable, Sendable {
    var agents: [Agent] = []
    var loops: [LoopStatus] = []
    var jobs: [LaunchdJob] = []

    typealias Agent = AgentSession
    typealias Subagent = AgentSubagent
    typealias LoopStatus = NotchCore.LoopStatus
}

/// Asks every enabled provider (Claude Code, Codex …) for its sessions, applies hook events on
/// top (they beat the files), and adds the loops of a `JobsProvider` connector and launchd jobs.
/// Everything is read-only; providers read incrementally, so a quiet poll costs a few `stat`s.
actor AgentScanner {
    static var claudeDir: URL { Runtime.claudeDir }

    /// Every provider this build knows, in display order.
    static let providerTypes: [any AgentProvider.Type] = [ClaudeCodeProvider.self, CodexProvider.self]

    private let claude = ClaudeCodeProvider(root: Runtime.claudeDir)
    private let codex = CodexProvider()
    private var jobs: [LaunchdJob] = []
    private var jobsCheckedAt = Date.distantPast
    /// Providers switched off in Settings › Providers.
    private var disabled: Set<String> = []
    /// Live hook events (pending approvals), newest per session.
    private var events: [AgentEvent] = []
    /// Providers that switched themselves off: why.
    private(set) var unsupported: [String: String] = [:]

    func setDisabled(_ ids: Set<String>) { disabled = ids }
    func setEvents(_ events: [AgentEvent]) { self.events = events }

    func scan(now: Date = Date(), includeJobs: Bool) async -> AgentSnapshot {
        var snapshot = AgentSnapshot()
        var sessions: [AgentSession] = []
        var fileTimes: [String: Date] = [:]
        if !disabled.contains(ClaudeCodeProvider.id) {
            sessions += await claude.scan(now: now).sessions
            fileTimes.merge(await claude.fileTimes) { a, _ in a }
        }
        if !disabled.contains(CodexProvider.id), CodexProvider.detect() {
            let result = await codex.scan(now: now)
            if let note = result.unsupported {
                if unsupported[CodexProvider.id] == nil { Log.app.error("Codex provider off: \(note, privacy: .public)") }
                unsupported[CodexProvider.id] = note
            } else {
                unsupported[CodexProvider.id] = nil
            }
            sessions += result.sessions
            fileTimes.merge(await codex.fileTimes) { a, _ in a }
        }
        snapshot.agents = SessionMerge.ordered(SessionMerge.apply(events, to: sessions, fileTimes: fileTimes))
        snapshot.loops = Runtime.jobs?.loops(now: now) ?? []
        if includeJobs, now.timeIntervalSince(jobsCheckedAt) > 30 {
            jobs = Self.launchdJobs()
            jobsCheckedAt = now
        }
        snapshot.jobs = jobs
        return snapshot
    }

    /// Plan limits of the tools that report them without credentials (Codex; Claude's come from
    /// its status line bridge).
    func usages(now: Date = Date()) async -> [AgentUsage] {
        guard !disabled.contains(CodexProvider.id), CodexProvider.detect() else { return [] }
        return await codex.usage(now: now).map { [$0] } ?? []
    }

    /// The projects the Claude app groups sessions under (see `ClaudeCodeProvider.knownProjects`).
    nonisolated static func knownProjects() -> [String] {
        ClaudeCodeProvider.knownProjects(root: claudeDir)
    }

    // MARK: launchd

    static func launchdJobs() -> [LaunchdJob] {
        guard !Runtime.launchdPrefix.isEmpty else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return LaunchdJob.parse(String(decoding: data, as: UTF8.self), prefix: Runtime.launchdPrefix)
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
