import XCTest
@testable import OsmoCore

/// Root-cause guard for the "new account already shows WhatsApp/LinkedIn/Instagram
/// connected" bug: a persisted `connections.json` must NEVER resurrect a
/// "connected" phase on load. Every connection re-verifies live (iMessage via the
/// FDA probe, backend platforms via reconcile).
final class ConnectionRehydrateTests: XCTestCase {

    func testConnectedPhasesNeverResurrectFromDisk() {
        XCTAssertEqual(ConnectionsManager.rehydrated(.live), .notConnected)
        XCTAssertEqual(ConnectionsManager.rehydrated(.backfilling(progress: 0.5)), .notConnected)
        XCTAssertEqual(ConnectionsManager.rehydrated(.linking(started: Date())), .notConnected)
        XCTAssertEqual(ConnectionsManager.rehydrated(.degraded(reason: "x")), .notConnected)
    }

    func testUserIntentAndBasePhasesSurvive() {
        XCTAssertEqual(ConnectionsManager.rehydrated(.paused), .paused)
        XCTAssertEqual(ConnectionsManager.rehydrated(.disconnected), .disconnected)
        XCTAssertEqual(ConnectionsManager.rehydrated(.notConnected), .notConnected)
    }

    /// reconcile(verify:) must pass the liveness flag through to the accounts
    /// fetch (and only then), and surface the wire's lastSyncAt per platform.
    @MainActor
    func testReconcileVerifyPassThroughAndLastSync() async throws {
        let log = RequestLog()
        let accountsBody = #"{"connections":[{"id":"c1","platform":"linkedin","status":"connected","displayName":"LinkedIn","backfillProgress":1,"createdAt":"2026-07-01T00:00:00Z","lastSyncAt":"2026-07-09T10:00:00Z"}]}"#
        let transport: BackendClient.DataTransport = { request in
            log.append(request)
            let respond = { (body: String) -> (Data, HTTPURLResponse) in
                (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                                                  httpVersion: nil, headerFields: nil)!)
            }
            let path = request.url!.path
            if path.contains("device/register") {
                return respond(#"{"deviceId":"d","deviceToken":"t","mode":"mock"}"#)
            }
            if path.contains("accounts") { return respond(accountsBody) }
            return respond("{}")
        }
        let client = BackendClient(baseURL: URL(string: "http://test")!,
                                   tokenStore: MemoryDeviceToken(), transport: transport)
        let persistURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("osmo-conn-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: persistURL) }
        let manager = ConnectionsManager(client: client, persistURL: persistURL,
                                         chatDBPath: URL(fileURLWithPath: "/nonexistent"))

        await manager.reconcile(verify: true)
        await manager.reconcile()   // existing callers, unchanged behavior

        let queries = log.all
            .filter { $0.url!.path.contains("accounts") }
            .map { $0.url!.query ?? "" }
        XCTAssertEqual(queries, ["verify=1", ""])
        XCTAssertEqual(manager.phases[.linkedin], .live)
        XCTAssertEqual(manager.lastSyncByPlatform[.linkedin],
                       ISO8601DateFormatter().date(from: "2026-07-09T10:00:00Z"))
    }

    final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _all: [URLRequest] = []
        func append(_ r: URLRequest) { lock.lock(); _all.append(r); lock.unlock() }
        var all: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _all }
    }
}
