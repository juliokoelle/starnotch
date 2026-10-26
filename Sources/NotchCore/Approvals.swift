import Darwin
import Foundation

/// A permission request, as a `PermissionRequest` hook receives it on stdin and forwards it to
/// the notch (see integrations/claude-code/starnotch-approvals). Claude Code and Codex send the
/// same fields; the hook script adds `starnotch_provider` for tools other than Claude Code.
public struct ApprovalRequest: Equatable, Sendable, Identifiable {
    public var id: String
    /// `ClaudeCodeProvider.id` or `CodexProvider.id`: decides the reply format.
    public var provider: String = "claude-code"
    public var sessionID: String?
    public var cwd: String?
    public var tool: String
    /// One line for the card: the command, the file, the URL.
    public var summary: String
    /// The full text behind the summary (shown on hover).
    public var detail: String
    /// `permission_suggestions` that add allow rules, kept for "Allow for session".
    public var allowRules: [[String: String]]
    /// An agent's question through the MCP server: up to four answers to pick from …
    public var options: [String] = []
    /// … and/or a field to type the answer.
    public var freeText = false

    /// A question that wants an answer rather than yes or no.
    public var asksForAnswer: Bool { !options.isEmpty || freeText }

    /// The hook's stdin JSON; nil unless it is a PermissionRequest with a tool name.
    public static func parse(_ data: Data, id: String = UUID().uuidString) -> ApprovalRequest? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["hook_event_name"] as? String == "PermissionRequest",
              let tool = object["tool_name"] as? String, !tool.isEmpty else { return nil }
        let input = object["tool_input"] as? [String: Any] ?? [:]
        let (summary, detail) = describe(tool: tool, input: input)
        var rules: [[String: String]] = []
        for suggestion in object["permission_suggestions"] as? [[String: Any]] ?? [] {
            guard suggestion["type"] as? String == "addRules", suggestion["behavior"] as? String == "allow" else { continue }
            for rule in suggestion["rules"] as? [[String: Any]] ?? [] {
                guard let name = rule["toolName"] as? String else { continue }
                var entry = ["toolName": name]
                if let content = rule["ruleContent"] as? String { entry["ruleContent"] = content }
                rules.append(entry)
            }
        }
        var request = ApprovalRequest(id: id, sessionID: object["session_id"] as? String, cwd: object["cwd"] as? String,
                                      tool: tool, summary: summary, detail: detail, allowRules: rules)
        if let provider = (object["starnotch_provider"] as? String)?.nilIfEmpty { request.provider = provider }
        if request.provider == mcpProvider {
            let options = (object["starnotch_options"] as? [String] ?? [])
                .map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)) }
                .filter { !$0.isEmpty }
            request.options = Array(options.prefix(4))
            request.freeText = object["starnotch_free_text"] as? Bool ?? false
        }
        return request
    }

    public init(id: String, provider: String = "claude-code", sessionID: String?, cwd: String?, tool: String,
                summary: String, detail: String, allowRules: [[String: String]]) {
        self.id = id
        self.provider = provider
        self.sessionID = sessionID
        self.cwd = cwd
        self.tool = tool
        self.summary = summary
        self.detail = detail
        self.allowRules = allowRules
    }

    /// Questions from any agent through Starnotch's MCP server (`mcp/`): `tool` names the asking
    /// client, `summary` and `detail` carry the question; the answer is allow (yes) or deny (no).
    public static let mcpProvider = "mcp"

    /// "Allow for session" adds a rule in Claude Code; Codex's hook can't carry one.
    public var supportsSessionRules: Bool { provider == "claude-code" }

    /// The session's id in the agents list (Codex ids carry the provider).
    public var agentID: String? {
        guard let sessionID else { return nil }
        return provider == "claude-code" ? sessionID : "\(provider):\(sessionID)"
    }

    static func describe(tool: String, input: [String: Any]) -> (String, String) {
        func string(_ key: String) -> String? {
            // Codex may send a command as an argument list.
            let value = input[key] as? String ?? (input[key] as? [String]).map { $0.joined(separator: " ") }
            return value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let full: String = switch tool {
        case "Bash": string("command") ?? ""
        case "Edit", "Write", "MultiEdit", "Read", "NotebookEdit": string("file_path") ?? string("notebook_path") ?? ""
        case "WebFetch": string("url") ?? ""
        case "WebSearch": string("query") ?? ""
        case "apply_patch":
            // Codex: a patch; the files it touches say more than its first line.
            Self.patchFiles(string("command") ?? "").map { "Edit " + $0 } ?? (string("command") ?? "")
        default:
            string("command") ?? string("file_path") ?? string("url") ?? string("description")
                ?? input.keys.sorted().prefix(3).joined(separator: ", ")
        }
        let line = full.split(whereSeparator: \.isNewline).first.map(String.init) ?? full
        if tool == "apply_patch" { return (line, string("command").map { $0.count > 2000 ? String($0.prefix(2000)) + "…" : $0 } ?? full) }
        let summary = line.count > 120 ? String(line.prefix(119)) + "…" : line
        return (summary, full.count > 2000 ? String(full.prefix(2000)) + "…" : full)
    }
}

extension ApprovalRequest {
    /// "a.swift, b.swift" from a Codex patch's "*** Update File: …" lines.
    static func patchFiles(_ patch: String) -> String? {
        let files = patch.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            for marker in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] where line.hasPrefix(marker) {
                return (String(line.dropFirst(marker.count)) as NSString).lastPathComponent
            }
            return nil
        }
        return files.isEmpty ? nil : files.joined(separator: ", ")
    }
}

/// What the user clicked in the notch.
public enum ApprovalDecision: Equatable, Sendable {
    case allowOnce, allowSession, deny
    /// The answer to an agent's question (an option or typed text), for the MCP server only.
    case answer(String)

    /// The hook's stdout for the request's tool.
    public func output(for request: ApprovalRequest) -> Data {
        if request.provider == ApprovalRequest.mcpProvider { return ApprovalFormat.mcp(self) }
        return request.provider == "codex" ? ApprovalFormat.codex(self) : claudeOutput(for: request)
    }

    /// Claude Code's stdout, exactly as its PermissionRequest decision control documents it.
    func claudeOutput(for request: ApprovalRequest) -> Data {
        var decision: [String: Any]
        switch self {
        case .allowOnce, .answer:
            decision = ["behavior": "allow"]
        case .allowSession:
            // Claude Code's own suggestions, kept in memory for this session only. Without one,
            // a Bash command is allowed for exactly this command; another tool as a whole.
            var rules: [[String: String]] = request.allowRules
            if rules.isEmpty {
                rules = request.tool == "Bash" && !request.detail.isEmpty
                    ? [["toolName": "Bash", "ruleContent": request.detail]]
                    : [["toolName": request.tool]]
            }
            decision = ["behavior": "allow",
                        "updatedPermissions": [["type": "addRules", "rules": rules, "behavior": "allow",
                                                "destination": "session"]]]
        case .deny:
            decision = ["behavior": "deny", "message": "Denied from the notch."]
        }
        let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        return (try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])) ?? Data()
    }
}

/// Reply formats per tool.
public enum ApprovalFormat {
    /// The MCP server's reply: the PermissionRequest shape (yes is allow, no is deny) plus the
    /// answer to a question.
    public static func mcp(_ decision: ApprovalDecision) -> Data {
        var output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest",
                                                            "decision": ["behavior": decision == .deny ? "deny" : "allow"]]]
        if case .answer(let text) = decision { output["starnotch_answer"] = text }
        return (try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])) ?? Data()
    }

    /// Codex's PermissionRequest output: allow or deny only. Codex fails closed on
    /// `updatedPermissions`, so "for this session" can't be expressed and is sent as a plain allow.
    public static func codex(_ decision: ApprovalDecision) -> Data {
        let body: [String: Any] = switch decision {
        case .allowOnce, .allowSession, .answer: ["behavior": "allow"]
        case .deny: ["behavior": "deny", "message": "Denied from the notch."]
        }
        let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": body]]
        return (try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])) ?? Data()
    }
}

/// The notch's end of the approvals socket: a Unix socket in the app's support folder (folder
/// 0700, socket 0600). Each connection carries one request; the reply is the hook's stdout (or
/// nothing, which leaves Claude Code's own prompt in charge). Only processes of the same user
/// are served.
public final class ApprovalServer: @unchecked Sendable {
    public typealias Handler = @Sendable (ApprovalRequest, _ reply: @escaping @Sendable (ApprovalDecision?) -> Void) -> Void

    public static let maxRequest = 512 * 1024
    public let path: String
    private let handler: Handler
    private let onCancel: @Sendable (String) -> Void
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "approvals.accept")

    /// - Parameters:
    ///   - handler: gets each request; call `reply` once (nil = no decision).
    ///   - onCancel: the hook went away before a reply (answered in the terminal): the request id.
    public init(path: String, handler: @escaping Handler, onCancel: @escaping @Sendable (String) -> Void = { _ in }) {
        self.path = path
        self.handler = handler
        self.onCancel = onCancel
    }

    public func start() throws {
        let folder = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        chmod(folder, 0o700)
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { close(fd); throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        let old = umask(0o177)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(old)
        guard bound == 0, listen(fd, 8) == 0 else { close(fd); throw POSIXError(.EADDRINUSE) }
        chmod(path, 0o600)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        // Accept through a dispatch source: cancelling it is the only place the descriptor is
        // closed, so no thread can ever accept on a reused descriptor number.
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { return }
                self?.serve(client)
            }
        }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    public func stop() {
        source?.cancel()
        source = nil
        unlink(path)
    }

    private func serve(_ client: Int32) {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { close(client); return }
        // Accepted sockets inherit the listener's non-blocking flag; reads here block (with a timeout).
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        DispatchQueue.global(qos: .userInitiated).async { [handler, onCancel] in
            // Read until the bytes parse as one request (the hook sends JSON, then closes its write side or not).
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 16_384)
            var request: ApprovalRequest?
            while data.count < Self.maxRequest {
                let n = read(client, &buffer, buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
                if let parsed = ApprovalRequest.parse(data) { request = parsed; break }
                // The hook sends one line; a full line that isn't a request ends it.
                if data.contains(0x0A) { break }
            }
            guard let request else { close(client); return }
            let state = Once()
            let finish: @Sendable (ApprovalDecision?) -> Void = { decision in
                guard state.claim() else { return }
                if let decision {
                    let out = decision.output(for: request)
                    _ = out.withUnsafeBytes { write(client, $0.baseAddress, out.count) }
                }
                // The watcher below owns the descriptor and closes it, only after this point.
                shutdown(client, SHUT_RDWR)
                state.finish()
            }
            handler(request, finish)
            // The hook keeps its side open and sends a newline now and then while it waits; end
            // of stream means it is gone (Claude Code took the answer in the terminal).
            DispatchQueue.global(qos: .utility).async {
                var sink = [UInt8](repeating: 0, count: 256)
                defer {
                    // Close only once the reply is written (a reply racing a close could otherwise
                    // land on a reused descriptor).
                    while !state.isFinished { usleep(10_000) }
                    close(client)
                }
                while !state.isDone {
                    var poller = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
                    guard poll(&poller, 1, 250) > 0 else { continue }
                    let n = recv(client, &sink, sink.count, MSG_DONTWAIT)
                    if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
                        if state.isDone { return }
                        finish(nil)
                        onCancel(request.id)
                        return
                    }
                }
            }
        }
    }
}

/// A flag that flips once, safely from any thread.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var finished = false

    var isDone: Bool { lock.lock(); defer { lock.unlock() }; return done }
    /// The claimant has completed its work.
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    func finish() { lock.lock(); finished = true; lock.unlock() }

    /// True for the first caller only.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
