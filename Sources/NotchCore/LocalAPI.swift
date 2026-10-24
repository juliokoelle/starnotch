import NotchCore
import Foundation

/// A status that scripts and loops post to the island:
/// `POST /status` on 127.0.0.1 with `Authorization: Bearer <token>`, or
/// `<scheme>://status?title=…` (the scheme is `Brand.urlScheme`).
public struct StatusPayload: Equatable, Sendable {
    public enum Tint: String, Sendable, CaseIterable {
        case accent, ok, waiting, critical, neutral
    }

    public var title: String
    public var detail: String?
    /// SF Symbol name; the app falls back to a default when it doesn't exist.
    public var icon: String?
    public var tint: Tint
    /// Same key replaces a waiting status (progress updates).
    public var key: String?
    /// http(s) link opened on click.
    public var url: URL?
    public var seconds: Double
    /// A loop reporting its state (`running`, `ok`, `fail`, `waiting`); the loops strip shows it.
    public var loop: String?
    public var state: String?

    public static let maxTitle = 80
    public static let maxDetail = 120

    public init(title: String, detail: String? = nil, icon: String? = nil, tint: Tint = .accent,
                key: String? = nil, url: URL? = nil, seconds: Double = 3) {
        self.title = title
        self.detail = detail
        self.icon = icon
        self.tint = tint
        self.key = key
        self.url = url
        self.seconds = seconds
    }

    public static let loopStates: Set<String> = ["running", "ok", "fail", "waiting"]

    public enum Problem: Error, Equatable {
        case missingTitle, badJSON
    }

    /// Validates and trims; unknown tints become `accent`, links other than http(s) are dropped,
    /// durations are kept between 1 and 10 seconds.
    public static func make(fields: [String: Any]) throws(Problem) -> StatusPayload {
        func text(_ key: String, max: Int) -> String? {
            guard let raw = fields[key] as? String else { return nil }
            let clean = raw.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return nil }
            return clean.count > max ? String(clean.prefix(max - 1)) + "…" : clean
        }
        let loop = text("loop", max: 60).flatMap { $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } ? $0 : nil }
        let state = (fields["state"] as? String).map { $0.lowercased() }.flatMap { loopStates.contains($0) ? $0 : nil }
        // A loop update needs no title: it names itself.
        guard let title = text("title", max: maxTitle) ?? loop.map(LoopStatus.displayName) else { throw .missingTitle }
        let url = (fields["url"] as? String).flatMap(URL.init(string:)).flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        let icon = text("icon", max: 60).flatMap { $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." } ? $0 : nil }
        let seconds = (fields["seconds"] as? Double) ?? (fields["seconds"] as? String).flatMap(Double.init) ?? 3
        var payload = StatusPayload(
            title: title,
            detail: text("detail", max: maxDetail),
            icon: icon,
            tint: (fields["tint"] as? String).flatMap { Tint(rawValue: $0.lowercased()) } ?? .accent,
            key: text("key", max: 60),
            url: url,
            seconds: min(10, max(1, seconds))
        )
        payload.loop = loop
        payload.state = state
        return payload
    }

    public static func make(json: Data) throws(Problem) -> StatusPayload {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { throw .badJSON }
        return try make(fields: object)
    }

    /// `starnotch://status?title=Build%20done&tint=ok`
    public static func make(url: URL) throws(Problem) -> StatusPayload {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var fields: [String: Any] = [:]
        for item in items { fields[item.name] = item.value ?? "" }
        return try make(fields: fields)
    }
}

/// A minimal HTTP/1.1 request, enough for the local status endpoint.
public struct HTTPRequest: Equatable, Sendable {
    public var method: String
    public var path: String
    /// Lowercased names.
    public var headers: [String: String]
    public var body: Data

    public enum Parse: Equatable {
        case complete(HTTPRequest)
        /// Wait for more bytes.
        case incomplete
        case invalid
    }

    public static let maxSize = 16 * 1024

    public static func parse(_ data: Data) -> Parse {
        guard data.count <= maxSize else { return .invalid }
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        guard let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count == 3, start[2].hasPrefix("HTTP/1.") else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .invalid }
        let body = data[end.upperBound...]
        if body.count < length { return .incomplete }
        return .complete(HTTPRequest(method: String(start[0]), path: String(start[1]), headers: headers, body: Data(body.prefix(length))))
    }

    /// Constant-time comparison of the bearer token.
    public func isAuthorized(token: String) -> Bool {
        guard !token.isEmpty, let header = headers["authorization"], header.hasPrefix("Bearer ") else { return false }
        let given = Array(header.dropFirst(7).utf8), expected = Array(token.utf8)
        guard given.count == expected.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(given, expected) { difference |= a ^ b }
        return difference == 0
    }
}
