import Testing
import Foundation
@testable import OsmoCore

@Suite("BackendClient — auth, retry, shaping")
struct BackendClientTests {

    /// Recording fake transport: scripted responses per path. Locking lives in
    /// synchronous helpers (NSLock is noasync in Swift 6 async contexts).
    final class FakeTransport: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [URLRequest] = []
        private var _script: [(match: String, status: Int, body: String)] = []

        var requests: [URLRequest] { lock.withLock { _requests } }
        var script: [(match: String, status: Int, body: String)] {
            get { lock.withLock { _script } }
            set { lock.withLock { _script = newValue } }
        }

        /// Record the request and pop the first matching one-shot entry.
        private func recordAndPop(_ request: URLRequest) -> (status: Int, body: String)? {
            lock.withLock {
                _requests.append(request)
                let path = request.url!.path
                guard let index = _script.firstIndex(where: { path.contains($0.match) }) else { return nil }
                let entry = _script.remove(at: index)
                return (entry.status, entry.body)
            }
        }

        func handler() -> BackendClient.DataTransport {
            { [self] request in
                let entry = recordAndPop(request) ?? (404, "{}")
                let response = HTTPURLResponse(url: request.url!, statusCode: entry.status,
                                               httpVersion: nil, headerFields: nil)!
                return (Data(entry.body.utf8), response)
            }
        }
    }

    private static let creds = #"{"deviceId":"dev-1","deviceToken":"tok-1","mode":"mock"}"#
    private static let creds2 = #"{"deviceId":"dev-2","deviceToken":"tok-2","mode":"mock"}"#
    private static let emptyBatch = #"{"contacts":[],"threads":[],"messages":[],"cursor":"0","hasMore":false}"#

    @Test("register persists credentials and reuses them")
    func registerOnce() async throws {
        let transport = FakeTransport()
        transport.script = [("device/register", 200, Self.creds),
                            ("sync/pull", 200, Self.emptyBatch)]
        let tokens = MemoryDeviceToken()
        let client = BackendClient(baseURL: URL(string: "http://test")!,
                                   tokenStore: tokens, transport: transport.handler())
        _ = try await client.pull(since: "")
        #expect(try tokens.load()?.deviceToken == "tok-1")
        // Bearer header attached to the authed call.
        let pullReq = transport.requests.first { $0.url!.path.contains("sync/pull") }
        #expect(pullReq?.value(forHTTPHeaderField: "Authorization") == "Bearer tok-1")
    }

    @Test("A first-ever device mint fires onReRegistered (covers the SSE-reconnect cursor reset)")
    func freshRegisterFiresReRegistered() async throws {
        // The SSE reconnect path re-registers via registerIfNeeded()→register(),
        // NOT via authed(). This proves that path resets the sync cursor too — the
        // keyless backend-restart self-heal depends on it.
        let transport = FakeTransport()
        transport.script = [("device/register", 200, Self.creds)]
        let client = BackendClient(baseURL: URL(string: "http://test")!,
                                   tokenStore: MemoryDeviceToken(), transport: transport.handler())
        let flagged = FlagBox()
        await client.setOnReRegistered { flagged.set() }
        _ = try await client.registerIfNeeded()
        #expect(flagged.isSet)
    }

    @Test("401 → re-register once → retry succeeds with the fresh token")
    func reauthOn401() async throws {
        let transport = FakeTransport()
        transport.script = [
            ("sync/pull", 401, "{}"),                 // first pull rejected
            ("device/register", 200, Self.creds2),    // re-register
            ("sync/pull", 200, Self.emptyBatch),      // retry OK
        ]
        let tokens = MemoryDeviceToken()
        try tokens.store(DeviceCredentials(deviceId: "dev-old", deviceToken: "tok-stale", mode: "mock"))
        let client = BackendClient(baseURL: URL(string: "http://test")!,
                                   tokenStore: tokens, transport: transport.handler())

        let flagged = FlagBox()
        await client.setOnReRegistered { flagged.set() }

        let batch = try await client.pull(since: "5")
        #expect(batch.cursor == "0")
        #expect(try tokens.load()?.deviceToken == "tok-2")
        #expect(flagged.isSet)
        // Retry carried the NEW token.
        let pulls = transport.requests.filter { $0.url!.path.contains("sync/pull") }
        #expect(pulls.count == 2)
        #expect(pulls.last?.value(forHTTPHeaderField: "Authorization") == "Bearer tok-2")
    }

    @Test("send posts the exact body and decodes the echoed message")
    func sendShaping() async throws {
        let transport = FakeTransport()
        let echo = #"{"message":{"platform":"linkedin","platformMessageID":"real-9","platformThreadID":"t1","senderHandle":null,"isFromMe":true,"text":"hi there","sentAt":"2026-07-04T10:00:00Z","readAt":null}}"#
        transport.script = [("device/register", 200, Self.creds),
                            ("sync/send", 200, echo)]
        let client = BackendClient(baseURL: URL(string: "http://test")!,
                                   tokenStore: MemoryDeviceToken(), transport: transport.handler())
        let message = try await client.send(platform: .linkedin, platformThreadID: "t1", text: "hi there")
        #expect(message.platformMessageID == "real-9")
        #expect(message.isFromMe)

        let sendReq = transport.requests.first { $0.url!.path.contains("sync/send") }
        let body = try JSONSerialization.jsonObject(with: sendReq!.httpBody!) as! [String: String]
        #expect(body == ["platform": "linkedin", "platformThreadID": "t1", "text": "hi there"])
    }

    @Test("non-200 non-401 surfaces as badStatus")
    func badStatus() async throws {
        let transport = FakeTransport()
        transport.script = [("device/register", 200, Self.creds),
                            ("accounts", 500, "{}")]
        let client = BackendClient(baseURL: URL(string: "http://test")!,
                                   tokenStore: MemoryDeviceToken(), transport: transport.handler())
        await #expect(throws: BackendClient.BackendError.badStatus(500)) {
            _ = try await client.accounts()
        }
    }

    final class FlagBox: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func set() { lock.lock(); flag = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }
}

extension BackendClientTests {
    static let enrichBundle = """
    {"profile":{"name":"Maya Render","headline":"Head of Growth at Reelio",
     "company":"Reelio","title":"Head of Growth","location":"San Francisco, CA",
     "summary":"Ships fast.","linkedinURL":"https://www.linkedin.com/in/maya",
     "positions":[{"title":"Head of Growth","company":"Reelio","period":"2023–present"}],
     "education":[{"school":"UC Berkeley","degree":"BA","period":"2014–2018"}]},
     "webFacts":[{"text":"Maya spoke on a panel.","url":"https://ex.example/p"}],
     "source":"both","fetchedAt":"2026-07-04T18:00:00Z"}
    """

    @Test("enrichPerson posts the wire request and decodes the bundle")
    func enrichPersonDecodes() async throws {
        let transport = FakeTransport()
        transport.script = [("device/register", 200, Self.creds),
                            ("enrich/person", 200, Self.enrichBundle)]
        let client = BackendClient(baseURL: URL(string: "http://test")!,
                                   tokenStore: MemoryDeviceToken(), transport: transport.handler())
        let out = try await client.enrichPerson(WireEnrichRequest(
            name: "Maya Render", linkedinHandle: "att-9", hints: ["growth"]))

        #expect(out.source == "both")
        #expect(out.profile?.headline == "Head of Growth at Reelio")
        #expect(out.profile?.positions.first?.company == "Reelio")
        #expect(out.webFacts.first?.url == "https://ex.example/p")

        let req = transport.requests.first { $0.url!.path.contains("enrich/person") }
        #expect(req?.httpMethod == "POST")
        let body = try JSONDecoder().decode(WireEnrichRequest.self, from: req!.httpBody!)
        #expect(body.name == "Maya Render")
        #expect(body.linkedinHandle == "att-9")
        #expect(body.hints == ["growth"])
    }
}
