import Testing
import Foundation
@testable import OsmoBrain
import OsmoCore

@Suite("Relationship model — composed per-person context + decision renderer")
struct RelationshipModelTests {
    let cal = Calendar.current
    func at(day: Int, hour: Int = 12) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 6, day: day, hour: hour))!
    }
    func turn(_ fromMe: Bool, _ text: String, _ d: Date) -> ThreadTurn {
        ThreadTurn(fromMe: fromMe, text: text, sentAt: d)
    }

    @Test("A thin thread composes without crashing and stays honest (no fabricated lines)")
    func thinThread() {
        let m = RelationshipModel.assemble(
            threadID: UUID(),
            displayName: "Sam", isGroup: false, personID: nil,
            turns: [turn(false, "hey", at(day: 1))], now: at(day: 2))
        let ctx = m.decisionContext(now: at(day: 2))
        #expect(ctx.contains("Sam"))
        // Insufficient rhythm/trajectory/vibe → those labels must NOT appear.
        #expect(!ctx.contains("Reply rhythm"))
        #expect(!ctx.contains("Trajectory"))
        #expect(!ctx.contains("Vibe"))
    }

    @Test("Ball reads 'they're waiting on you' when their message is last")
    func ballTheirs() {
        let m = RelationshipModel.assemble(
            threadID: UUID(),
            displayName: "Sam", isGroup: false, personID: nil,
            turns: [turn(true, "hi", at(day: 1)), turn(false, "what's up?", at(day: 1, hour: 13))],
            now: at(day: 1, hour: 14))
        #expect(m.read.ball == .theirs)
        #expect(m.decisionContext(now: at(day: 1, hour: 14)).contains("waiting on you"))
    }

    @Test("An upcoming important date within 3 weeks surfaces in the decision context")
    func upcomingDateSurfaces() {
        let birthday = ImportantDate(id: "b", threadID: UUID(), kind: .birthday,
                                     label: "Sam's birthday", month: 6, day: 20,
                                     recurring: true, source: .manual)
        let m = RelationshipModel.assemble(
            threadID: UUID(),
            displayName: "Sam", isGroup: false, personID: nil,
            turns: [turn(false, "hey", at(day: 1))],
            importantDates: [birthday], now: at(day: 10))
        #expect(m.decisionContext(now: at(day: 10)).contains("Sam's birthday"))
    }

    @Test("A date far in the future does NOT surface")
    func farDateHidden() {
        let xmas = ImportantDate(id: "x", threadID: UUID(), kind: .anniversary,
                                 label: "anniversary", month: 12, day: 25,
                                 recurring: true, source: .manual)
        let m = RelationshipModel.assemble(
            threadID: UUID(),
            displayName: "Sam", isGroup: false, personID: nil,
            turns: [turn(false, "hey", at(day: 1))],
            importantDates: [xmas], now: at(day: 10))
        #expect(!m.decisionContext(now: at(day: 10)).contains("anniversary"))
    }

    @Test("Memory context (goals/facts) is injected when present")
    func memoryInjected() {
        var mem = RelationshipMemory(personID: UUID())
        mem.addFact("always ask about her thesis", kind: .doRule)
        let m = RelationshipModel.assemble(
            threadID: UUID(),
            displayName: "Sam", isGroup: false, personID: mem.personID,
            turns: [turn(false, "hey", at(day: 1))],
            memory: mem, now: at(day: 2))
        #expect(m.decisionContext(now: at(day: 2)).contains("thesis"))
    }

    @Test("Commitments the user made surface from intel")
    func commitmentsSurface() {
        let intel = ThreadIntel(commitments: ["send her the deck"])
        let m = RelationshipModel.assemble(
            threadID: UUID(),
            displayName: "Sam", isGroup: false, personID: nil,
            turns: [turn(false, "hey", at(day: 1))],
            intel: intel, now: at(day: 2))
        #expect(m.decisionContext(now: at(day: 2)).contains("send her the deck"))
    }
}
