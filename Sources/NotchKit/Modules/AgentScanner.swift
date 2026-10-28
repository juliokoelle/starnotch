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
    static let providerTypes: [any AgentProvider.Type] = [ClaudeCodeProvider.self, CodexProvider.self,
                                                          CursorProvider.self, CopilotProvider.self, GeminiProvider.self,
                                                          OpencodeProvider.self]

    private let claude = ClaudeCodeProvider(root: Runtime.claudeDir)
    private let codex = CodexProvider()
    /// Tools whose live state comes from hooks (and their files where they keep any).
    private let hooked: [any HookSessionSource] = [CursorProvider(), CopilotProvider(), GeminiProvider(), OpencodeProvider()]
    /// Which hooked tools are on this Mac, checked once a minute.
    private var detected: Set<String> = []
    private var detectedAt = Date.distantPast
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
        if now.timeIntervalSince(detectedAt) > 60 {
            detected = Set(hooked.map { type(of: $0) }.filter { $0.detect() }.map { $0.id })
            detectedAt = now
        }
        for provider in hooked {
            let id = type(of: provider).id
            guard !disabled.contains(id), detected.contains(id) else { continue }
            sessions += await provider.scan(now: now).sessions
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

    /// A status hook of another tool arrived on the approvals socket (see `HookUpdate`): to its
    /// provider. True when it was one.
    @discardableResult
    func ingest(_ data: Data, now: Date = Date()) async -> Bool {
        guard let update = HookUpdate.parse(data, now: now) else { return false }
        return await ingest(update)
    }

    @discardableResult
    func ingest(_ update: HookUpdate) async -> Bool {
        guard let provider = hooked.first(where: { type(of: $0).id == update.provider }) else { return false }
        // A hook proves the tool is here, even where its folder isn't.
        detected.insert(update.provider)
        await provider.ingest(update)
        return true
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
