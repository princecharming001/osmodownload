import Testing
import Foundation
@testable import OsmoCore

@Suite("Connection state machine — the reducer table")
struct ConnectionStateTests {
    typealias SM = ConnectionStateMachine

    @Test("Happy path: notConnected → linking → backfilling → live")
    func happyPath() {
        let t0 = Date()
        var phase = ConnectionPhase.notConnected
        phase = SM.reduce(phase, .beginLink(now: t0))
        #expect(phase == .linking(started: t0))
        phase = SM.reduce(phase, .statusEvent("backfilling"))
        #expect(phase == .backfilling(progress: 0))
        phase = SM.reduce(phase, .backfillProgress(0.4))
        #expect(phase == .backfilling(progress: 0.4))
        phase = SM.reduce(phase, .statusEvent("connected"))
        #expect(phase == .live)
    }

    @Test("Degraded on provider-session drop; reconnect returns to live")
    func degraded() {
        var phase = ConnectionPhase.live
        phase = SM.reduce(phase, .statusEvent("degraded"))
        guard case .degraded = phase else { Issue.record("expected degraded"); return }
        // Reconnect wizard → connected again.
        phase = SM.reduce(phase, .beginLink(now: Date()))
        phase = SM.reduce(phase, .statusEvent("connected"))
        #expect(phase == .live)
    }

    @Test("Snapshot heals: absent on backend collapses to notConnected — except mid-wizard")
    func snapshotHeals() {
        // Live connection vanished (dev-server restart) → notConnected.
        #expect(SM.reduce(.live, .accountsSnapshot(present: false, status: nil)) == .notConnected)
        #expect(SM.reduce(.degraded(reason: "x"), .accountsSnapshot(present: false, status: nil)) == .notConnected)
        // Mid-wizard, absence is expected — keep waiting.
        let linking = ConnectionPhase.linking(started: Date())
        #expect(SM.reduce(linking, .accountsSnapshot(present: false, status: nil)) == linking)
        // Present snapshot adopts the backend status.
        #expect(SM.reduce(.notConnected, .accountsSnapshot(present: true, status: "connected")) == .live)
        #expect(SM.reduce(.live, .accountsSnapshot(present: true, status: "paused")) == .paused)
    }

    @Test("Abandoned wizard times out after 10 minutes")
    func linkTimeout() {
        let started = Date(timeIntervalSinceNow: -11 * 60)
        let phase = ConnectionPhase.linking(started: started)
        #expect(SM.reduce(phase, .linkTimeout(now: Date())) == .notConnected)
        // Fresh wizard is untouched.
        let fresh = ConnectionPhase.linking(started: Date())
        #expect(SM.reduce(fresh, .linkTimeout(now: Date())) == fresh)
        // Non-linking phases ignore timeouts.
        #expect(SM.reduce(.live, .linkTimeout(now: Date())) == .live)
    }

    @Test("Unknown status strings leave the phase unchanged (forward compat)")
    func unknownStatus() {
        #expect(SM.reduce(.live, .statusEvent("quantum")) == .live)
    }

    @Test("backfillProgress at 1.0 does not regress a live phase")
    func progressComplete() {
        #expect(SM.reduce(.live, .backfillProgress(1.0)) == .live)
        #expect(SM.reduce(.backfilling(progress: 0.9), .backfillProgress(1.0)) == .backfilling(progress: 0.9))
    }
}
