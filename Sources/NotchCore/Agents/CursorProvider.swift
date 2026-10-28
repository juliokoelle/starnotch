import Foundation

/// Cursor (the agent in the editor and `cursor-agent` in a terminal). Its state comes from the
/// hooks in `~/.cursor/hooks.json` (set up on the consent page); its files hold no live status
/// we can read without its private database. Shell and MCP calls can be approved from the island:
/// Cursor's `beforeShellExecution` and `beforeMCPExecution` take allow, deny or ask.
public actor CursorProvider: AgentProvider, HookSessionSource {
    public static let id = "cursor"
    public static let displayName = "Cursor"

    public static var defaultRoot: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cursor") }
    public static let bundleIDs = ["com.todesktop.230313mzl4w4u92"]

    public static func detect() -> Bool {
        FileManager.default.fileExists(atPath: defaultRoot.path)
            || FileManager.default.fileExists(atPath: "/Applications/Cursor.app")
    }

    private var tool: HookedTool

    public init(useProcesses: Bool = true) {
        tool = HookedTool(names: ["cursor-agent"], scripts: ["cursor-agent"], useProcesses: useProcesses)
    }

    public nonisolated var watchPaths: [URL] { [] }

    public func ingest(_ update: HookUpdate) { tool.hooks.apply(update) }

    public func scan(now: Date) async -> ProviderScan {
        ProviderScan(sessions: tool.sessions(provider: Self.id, now: now))
    }
}
