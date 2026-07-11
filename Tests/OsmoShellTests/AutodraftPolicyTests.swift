import Testing
import Foundation
@testable import OsmoShell
import OsmoCore

@Suite("AutodraftPolicy — every guard for 'should Osmo autodraft this thread'")
struct AutodraftPolicyTests {
    private var now: Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 6; comps.day = 1; comps.hour = 10
        return Calendar.current.date(from: comps)!
    }
    private var todayKey: String { "2026-06-01" }
    private var freshCap: AutodraftCapState { AutodraftCapState(day: todayKey, used: 0) }

    private func decide(enabled: Bool = true, isPro: Bool = true, isGroup: Bool = false,
                        isHuman: Bool = true, status: TextingStatus = .needsReply,
                        existingDraft: (text: String, isAuto: Bool)? = nil,
                        cap: AutodraftCapState? = nil, heldBack: Bool = false) -> AutodraftPolicy.Decision {
        AutodraftPolicy.decide(enabled: enabled, isPro: isPro, isGroup: isGroup, isHuman: isHuman,
                               status: status, existingDraft: existingDraft,
                               cap: cap ?? freshCap, now: now, heldBack: heldBack)
    }

    @Test("The happy path: go") func happyPath() {
        #expect(decide().go == true)
    }

    @Test("Held back blocks even a needs-reply thread (give them space)") func heldBackBlocks() {
        let d = decide(heldBack: true)
        #expect(d.go == false)
        #expect(d.reason == "held back — giving them space")
    }

    @Test("Disabled toggle blocks") func disabledBlocks() {
        let d = decide(enabled: false)
        #expect(d.go == false); #expect(d.reason == "autodraft is off")
    }

    @Test("Free tier blocks — Pro only") func notProBlocks() {
        #expect(decide(isPro: false).go == false)
    }

    @Test("Group threads never autodraft") func groupBlocks() {
        #expect(decide(isGroup: true).go == false)
    }

    @Test("Non-human threads never autodraft") func nonHumanBlocks() {
        #expect(decide(isHuman: false).go == false)
    }

    @Test("Only needsReply status qualifies") func wrongStatusBlocks() {
        for status: TextingStatus in [.leftOnRead, .waiting, .ghosted, .quiet, .sayHi] {
            #expect(decide(status: status).go == false)
        }
    }

    @Test("Never overwrites text the user actually typed") func userDraftBlocks() {
        let d = decide(existingDraft: (text: "hey sorry for the delay", isAuto: false))
        #expect(d.go == false); #expect(d.reason == "user has an unsent draft")
    }

    @Test("A stale AUTODRAFT (isAuto: true) does NOT block a fresh one") func staleAutodraftAllows() {
        let d = decide(existingDraft: (text: "an old autodraft", isAuto: true))
        #expect(d.go == true)
    }

    @Test("An empty existing draft (any isAuto) does not block") func emptyDraftAllows() {
        #expect(decide(existingDraft: (text: "", isAuto: false)).go == true)
    }

    @Test("Daily cap: blocked once the limit is reached, same day") func capReached() {
        let full = AutodraftCapState(day: todayKey, used: AutodraftPolicy.dailyCap)
        let d = decide(cap: full)
        #expect(d.go == false); #expect(d.reason == "daily cap reached")
    }

    @Test("Cap increments by one on go, day key preserved") func capIncrements() {
        let d = decide()
        #expect(d.newCap.used == 1)
        #expect(d.newCap.day == todayKey)
    }

    @Test("A cap from a PREVIOUS day rolls over to zero-used today, then goes") func capRollsOverAcrossDays() {
        let staleCap = AutodraftCapState(day: "2020-01-01", used: AutodraftPolicy.dailyCap)   // maxed out — but stale
        let d = decide(cap: staleCap)
        #expect(d.go == true)
        #expect(d.newCap.used == 1)
        #expect(d.newCap.day == todayKey)
    }
}
