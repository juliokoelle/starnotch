import Foundation
import Network
import NotchCore

/// The token for the local status API, in `~/Library/Application Support/<App>/api-token`
/// (folder 0700, file 0600). Created when the API is switched on; never logged or shown.
enum APIToken {
    static var folder: URL { Brand.supportFolder }

    static var file: URL { folder.appending(path: "api-token") }

    /// Creates the support folder with 0700 if needed.
    @discardableResult
    static func ensureFolder() -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            return true
        } catch {
            return false
        }
    }

    static func load() -> String? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            if let existing = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               existing.count >= 32 {
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                return existing
            }
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
            let token = bytes.map { String(format: "%02x", $0) }.joined()
            guard fm.createFile(atPath: file.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600]) else { return nil }
            return token
        } catch {
            Log.app.error("API token: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

/// `POST http://127.0.0.1:<port>/status` (port 47789 unless config.toml says otherwise) with `Authorization: Bearer <token>` and a JSON body
/// (`title`, optional `detail`, `icon`, `tint`, `key`, `url`, `seconds`) shows a sneak peek.
/// Bound to the loopback interface only; nothing else on the network can reach it.
final class LocalAPIServer: @unchecked Sendable {
    static var port: UInt16 { Runtime.apiPort }

    private let token: String
    private let onStatus: @Sendable (StatusPayload) -> Void
    private var listener: NWListener?
    private let queue = DispatchQueue(label: Brand.identifier + ".api")

    init(token: String, onStatus: @escaping @Sendable (StatusPayload) -> Void) {
        self.token = token
        self.onStatus = onStatus
    }

    func start() {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        parameters.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state { Log.app.error("Local API: \(error.localizedDescription, privacy: .public)") }
            }
            listener.start(queue: queue)
            self.listener = listener
            Log.app.info("Local API on 127.0.0.1:\(Self.port)")
        } catch {
            Log.app.error("Local API failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        // Belt and braces next to the loopback-only listener.
        if case .hostPort(let host, _) = connection.endpoint, !"\(host)".hasPrefix("127.0.0.1"), "\(host)" != "::1" {
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        receive(connection, buffer: Data())
        // Slow or stuck clients don't keep a connection open.
        queue.asyncAfter(deadline: .now() + 5) { connection.cancel() }
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: HTTPRequest.maxSize) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPRequest.parse(buffer) {
            case .complete(let request):
                self.respond(to: request, on: connection)
            case .incomplete where !isComplete && error == nil:
                self.receive(connection, buffer: buffer)
            case .incomplete, .invalid:
                self.send(400, ["error": "bad request"], on: connection)
            }
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) {
        guard request.isAuthorized(token: token) else {
            send(401, ["error": "missing or wrong token"], on: connection)
            return
        }
        switch (request.method, request.path) {
        case ("POST", "/status"):
            do {
                let status = try StatusPayload.make(json: request.body)
                onStatus(status)
                send(200, ["ok": true], on: connection)
            } catch {
                send(400, ["error": error == .missingTitle ? "title is required" : "body must be JSON"], on: connection)
            }
        case ("GET", "/health"):
            send(200, ["ok": true], on: connection)
        default:
            send(404, ["error": "POST /status"], on: connection)
        }
    }

    private func send(_ code: Int, _ body: [String: Any], on connection: NWConnection) {
        let json = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found"][code] ?? "Error"
        var head = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n"
        if code == 401 { head = head.replacingOccurrences(of: "Connection: close", with: "WWW-Authenticate: Bearer\r\nConnection: close") }
        connection.send(content: Data(head.utf8) + json, completion: .contentProcessed { _ in connection.cancel() })
    }
}
