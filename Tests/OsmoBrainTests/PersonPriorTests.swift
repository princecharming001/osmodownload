import Testing
import Foundation
@testable import OsmoBrain
import OsmoCore

@Suite("Person prior + decision budget — the learning loop")
struct PersonPriorTests {
    let cal = Calendar.current
    func at(day: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 6, day: day, hour: 12))! }
    let person = UUID()
    func outcome(_ o: OutcomeKind, _ day: Int, family: String = "silence", gesture: String? = nil) -> SuggestionOutcome {
        SuggestionOutcome(decisionID: "d", threadID: UUID(), personID: person,
                          decisionKind: "reachOut", gestureKind: gesture, family: family,
                          outcome: o, createdAt: at(day: day))
    }

    @Test("No history → neutral weight (1.0), nothing quieted")
    func neutral() {
        let p = PersonPrior.from([], now: at(day: 30))
        #expect(p.nudgeWeight(family: "silence") == 1.0)
        #expect(!p.isQuiet(family: "silence", now: at(day: 30)))
    }

    @Test("Acting raises the family weight; ignoring lowers it")
    func actVsIgnore() {
        let up = PersonPrior.from([outcome(.acted, 1), outcome(.acted, 2)], now: at(day: 3))
        let down = PersonPrior.from([outcome(.dismissedSeen, 1), outcome(.dismissedSeen, 2)], now: at(day: 3))
        #expect(up.nudgeWeight(family: "silence") > 1.0)
        #expect(down.nudgeWeight(family: "silence") < 1.0)
    }

    @Test("Weight never decays below the floor (a person is never fully silenced by weight alone)")
    func floor() {
        let many = (1...20).map { outcome(.dismissedSeen, $0) }
        let p = PersonPrior.from(many, now: at(day: 21))
        #expect(p.nudgeWeight(family: "silence") >= 0.3)
    }

    @Test("Weight mean-reverts toward 1.0 over time (absence is not distrust)")
    func meanReversion() {
        let recent = PersonPrior.from([outcome(.dismissedSeen, 1)], now: at(day: 2))
        let ancient = PersonPrior.from([outcome(.dismissedSeen, 1)], now: at(day: 200))
        #expect(recent.nudgeWeight(family: "silence") < ancient.nudgeWeight(family: "silence"))
        #expect(abs(ancient.nudgeWeight(family: "silence") - 1.0) < 0.1)   // nearly neutral again
    }

    @Test("expired-unseen outcomes are NEUTRAL — they don't move the weight")
    func expiredNeutral() {
        let p = PersonPrior.from([outcome(.expiredUnseen, 1), outcome(.expiredUnseen, 2)], now: at(day: 3))
        #expect(p.nudgeWeight(family: "silence") == 1.0)
    }

    @Test("Three straight dismissals in a family set a quiet window")
    func quietAfterThree() {
        let p = PersonPrior.from([outcome(.dismissedSeen, 1), outcome(.dismissedSeen, 2), outcome(.dismissedSeen, 3)],
                                 now: at(day: 4))
        #expect(p.isQuiet(family: "silence", now: at(day: 4)))
        #expect(!p.isQuiet(family: "silence", now: at(day: 30)))   // window expires
    }

    @Test("An act resets the ignore run (no quiet window)")
    func actResetsRun() {
        let p = PersonPrior.from([outcome(.dismissedSeen, 1), outcome(.dismissedSeen, 2),
                                  outcome(.acted, 3), outcome(.dismissedSeen, 4)], now: at(day: 5))
        #expect(!p.isQuiet(family: "silence", now: at(day: 5)))
    }

    @Test("Passive misses (ignoredSeen) never quiet a person — only active dismissals do")
    func passiveMissesDontQuiet() {
        // 3 passive ignoredSeen (surfaced, aged out) must NOT open a quiet window.
        let passive = PersonPrior.from([outcome(.ignoredSeen, 1), outcome(.ignoredSeen, 2), outcome(.ignoredSeen, 3)],
                                       now: at(day: 4))
        #expect(!passive.isQuiet(family: "silence", now: at(day: 4)))
        // Two passive + one real dismissal is still only ONE active dismissal → no quiet.
        let mixed = PersonPrior.from([outcome(.ignoredSeen, 1), outcome(.ignoredSeen, 2), outcome(.dismissedSeen, 3)],
                                     now: at(day: 4))
        #expect(!mixed.isQuiet(family: "silence", now: at(day: 4)))
    }

    @Test("A celebration gesture is NEVER category-suppressed (a real new-baby moment can't be muted)")
    func celebrateNeverSuppressed() {
        let p = PersonPrior.from([outcome(.dismissedSeen, 1, family: "sensitive", gesture: "celebrate"),
                                  outcome(.dismissedSeen, 2, family: "sensitive", gesture: "celebrate"),
                                  outcome(.dismissedSeen, 3, family: "sensitive", gesture: "celebrate")],
                                 now: at(day: 4))
        #expect(!p.suppressedGestureKinds.contains("celebrate"))
    }

    @Test("Learning is per-family: ignoring 'effort' never quiets 'date'")
    func perFamilyIsolation() {
        let p = PersonPrior.from([outcome(.dismissedSeen, 1, family: "effort"),
                                  outcome(.dismissedSeen, 2, family: "effort"),
                                  outcome(.dismissedSeen, 3, family: "effort")], now: at(day: 4))
        #expect(p.isQuiet(family: "effort", now: at(day: 4)))
        #expect(!p.isQuiet(family: "date", now: at(day: 4)))
        #expect(p.nudgeWeight(family: "date") == 1.0)
    }

    @Test("Repeatedly dismissing a gesture kind suppresses it — EXCEPT life events")
    func gestureSuppression() {
        let flowers = PersonPrior.from([outcome(.dismissedSeen, 1, family: "date", gesture: "sendFlowers"),
                                        outcome(.dismissedSeen, 2, family: "date", gesture: "sendFlowers")],
                                       now: at(day: 3))
        #expect(flowers.suppressedGestureKinds.contains("sendFlowers"))
        // condolence is NEVER category-suppressed, even after repeated dismissals.
        let condolence = PersonPrior.from([outcome(.dismissedSeen, 1, family: "sensitive", gesture: "condolence"),
                                           outcome(.dismissedSeen, 2, family: "sensitive", gesture: "condolence"),
                                           outcome(.dismissedSeen, 3, family: "sensitive", gesture: "condolence")],
                                          now: at(day: 4))
        #expect(!condolence.suppressedGestureKinds.contains("condolence"))
    }

    @Test("Multi-cycle simulation: weight stays bounded no matter the sequence")
    func multiCycleBounds() {
        var outcomes: [SuggestionOutcome] = []
        for day in 1...40 {
            outcomes.append(outcome(day % 3 == 0 ? .acted : .dismissedSeen, day))
            let p = PersonPrior.from(outcomes, now: at(day: day + 1))
            let w = p.nudgeWeight(family: "silence")
            #expect(w >= 0.3 && w <= 2.0)   // never escapes the clamp
        }
    }

    // MARK: Decision budget

    @Test("No outcome data → the moderate default budget")
    func budgetDefault() {
        #expect(DecisionBudget.daily([], now: at(day: 10)) == 10)
    }

    @Test("A high act-rate yields a higher budget than a low one")
    func budgetScales() {
        let high = (1...10).map { outcome(.acted, $0) }
        let low = (1...10).map { outcome(.dismissedSeen, $0) }
        #expect(DecisionBudget.daily(high, now: at(day: 11)) > DecisionBudget.daily(low, now: at(day: 11)))
    }

    @Test("The budget never drops below its floor")
    func budgetFloor() {
        let allIgnored = (1...20).map { outcome(.dismissedSeen, $0) }
        #expect(DecisionBudget.daily(allIgnored, now: at(day: 21), floor: 4) >= 4)
    }

    @Test("expired-unseen outcomes are excluded from the act-rate")
    func budgetExcludesExpired() {
        // All expired-unseen → treated as no data → default, not a zero act-rate.
        let expired = (1...10).map { outcome(.expiredUnseen, $0) }
        #expect(DecisionBudget.daily(expired, now: at(day: 11)) == 10)
    }
}
