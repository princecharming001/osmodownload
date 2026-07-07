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
}
