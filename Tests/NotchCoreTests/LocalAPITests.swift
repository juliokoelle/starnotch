import Testing
import TestSupport
@testable import NotchCore

@Suite struct LocalAPITests {
    @Test func payloadFromJSON() throws {
        let json = Bytes.data(#"{"title":"Digest fertig","detail":"5 Quellen","tint":"OK","icon":"checkmark.circle","key":"digest","url":"https://example.com","seconds":4}"#)
        let status = try StatusPayload.make(json: json)
        #expect(status.title == "Digest fertig")
        #expect(status.detail == "5 Quellen")
        #expect(status.tint == .ok)
        #expect(status.icon == "checkmark.circle")
        #expect(status.key == "digest")
        #expect(status.url?.host == "example.com")
        #expect(status.seconds == 4)
    }

    @Test func payloadIsSanitized() throws {
        let long = String(repeating: "x", count: 200)
        let status = try StatusPayload.make(fields: ["title": "  \(long)\n", "tint": "rainbow", "url": "file:///etc/passwd",
                                                    "icon": "x; rm", "seconds": 99.0])
        #expect(status.title.count == StatusPayload.maxTitle)
        #expect(status.tint == .accent)
        #expect(status.url == nil)
        #expect(status.icon == nil)
        #expect(status.seconds == 10)
        #expect(throws: StatusPayload.Problem.missingTitle) { try StatusPayload.make(fields: ["title": "   "]) }
        #expect(throws: StatusPayload.Problem.badJSON) { try StatusPayload.make(json: Bytes.data("nope")) }
    }

    @Test func payloadFromURL() throws {
        let status = try StatusPayload.make(url: Bytes.url("notchswitcher://status?title=Build%20done&tint=ok&seconds=2"))
        #expect(status.title == "Build done")
        #expect(status.tint == .ok)
        #expect(status.seconds == 2)
    }

    @Test func parsesRequestsInPieces() {
        let full = "POST /status HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer abc123\r\nContent-Length: 16\r\n\r\n{\"title\":\"Hi\"}  "
        #expect(HTTPRequest.parse(Bytes.data(String(full.prefix(30)))) == .incomplete)
        #expect(HTTPRequest.parse(Bytes.data(String(full.dropLast(4)))) == .incomplete)
        guard case .complete(let request) = HTTPRequest.parse(Bytes.data(full)) else {
            Issue.record("not parsed")
            return
        }
        #expect(request.method == "POST")
        #expect(request.path == "/status")
        #expect(request.body.count == 16)
        #expect(request.isAuthorized(token: "abc123"))
        #expect(!request.isAuthorized(token: "abc124"))
        #expect(!request.isAuthorized(token: ""))
    }

    @Test func rejectsGarbage() {
        #expect(HTTPRequest.parse(Bytes.data("hello\r\n\r\n")) == .invalid)
        #expect(HTTPRequest.parse(Bytes.data("GET / HTTP/1.1\r\nno colon\r\n\r\n")) == .invalid)
        #expect(HTTPRequest.parse(Bytes.data(String(repeating: "a", count: HTTPRequest.maxSize + 1))) == .invalid)
    }
}
