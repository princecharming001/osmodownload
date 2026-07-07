import Testing
import Foundation
@testable import OsmoShell

@Suite("Entitlements — the metered thing that converts")
struct EntitlementsTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Free tier meters drafts and cuts off at the cap")
    func freeMeter() {
        var s = Entitlements.State(weekStartedAt: t0)
        for i in 0..<Entitlements.freeDraftsPerWeek {
            let d = Entitlements.decideDraft(s, now: t0.addingTimeInterval(Double(i)))
            #expect(d.allowed)
            s = d.newState
        }
        let over = Entitlements.decideDraft(s, now: t0.addingTimeInterval(1000))
        #expect(!over.allowed)
        #expect(over.remaining == 0)
    }

    @Test("The meter resets weekly")
    func weeklyReset() {
        var s = Entitlements.State(draftsThisWeek: Entitlements.freeDraftsPerWeek, weekStartedAt: t0)
        #expect(!Entitlements.decideDraft(s, now: t0.addingTimeInterval(6 * 86_400)).allowed)
        let d = Entitlements.decideDraft(s, now: t0.addingTimeInterval(8 * 86_400))
        #expect(d.allowed)                       // new week, fresh meter
        s = d.newState
        #expect(s.draftsThisWeek == 1)
    }

    @Test("Trial = unlimited, then silently degrades to free at expiry")
    func trialLifecycle() {
        var s = Entitlements.startTrial(Entitlements.State(weekStartedAt: t0), now: t0)
        #expect(s.tier == .trial)
        #expect(Entitlements.trialDaysLeft(s, now: t0) == Entitlements.trialDays)
        // Unlimited during trial.
        s.draftsThisWeek = 999
        #expect(Entitlements.decideDraft(s, now: t0.addingTimeInterval(86_400)).allowed)
        // Day 15: degraded to free; meter applies (fresh week → allowed once).
        let after = Entitlements.decideDraft(s, now: t0.addingTimeInterval(15 * 86_400))
        #expect(after.newState.tier == .free)
        #expect(after.allowed)                   // week rolled over with it
    }

    @Test("Restarting the trial never extends it")
    func trialNoRestart() {
        let started = Entitlements.startTrial(Entitlements.State(weekStartedAt: t0), now: t0)
        // 20 days later, trying to 'start' again must NOT re-grant trial.
        let again = Entitlements.startTrial(started, now: t0.addingTimeInterval(20 * 86_400))
        #expect(again.trialStartedAt == started.trialStartedAt)
        let d = Entitlements.decideDraft(again, now: t0.addingTimeInterval(20 * 86_400))
        #expect(d.newState.tier == .free)
    }

    @Test("Pro is unlimited")
    func pro() {
        let s = Entitlements.State(tier: .pro, draftsThisWeek: 10_000, weekStartedAt: t0)
        let d = Entitlements.decideDraft(s, now: t0)
        #expect(d.allowed)
        #expect(d.remaining == nil)
    }

    @Test("Peek (consume:false) never burns the meter")
    func peek() {
        let s = Entitlements.State(weekStartedAt: t0)
        let d = Entitlements.decideDraft(s, now: t0, consume: false)
        #expect(d.allowed)
        #expect(d.newState.draftsThisWeek == 0)
    }
}
