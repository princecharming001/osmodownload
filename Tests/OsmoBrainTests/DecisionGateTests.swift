import Testing
import Foundation
@testable import OsmoBrain
import OsmoCore

@Suite("Decision gate — cluster scoring, suppressors, sensitive-tier enforcement")
struct DecisionGateTests {
    let cal = Calendar.current
    func at(day: Int, hour: Int = 12) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 6, day: day, hour: hour))!
    }
    func turn(_ fromMe: Bool, _ text: String, _ d: Date, read: Date? = nil) -> ThreadTurn {
        ThreadTurn(fromMe: fromMe, text: text, sentAt: d, readAt: read)
    }

    /// A model with a controllable set of signals. We build turns that produce
    /// the reads we want, but for precision most tests inject via importantDates
    /// / intel / sensitiveOccasion which the gate reads directly.
    func model(threadID: UUID = UUID(), name: String = "Sam", isGroup: Bool = false,
               turns: [ThreadTurn] = [], dates: [ImportantDate] = [],
               intel: ThreadIntel? = nil, sensitive: SensitiveOccasion? = nil,
               now: Date) -> RelationshipModel {
        RelationshipModel.assemble(
            threadID: threadID, displayName: name, isGroup: isGroup, personID: nil,
            turns: turns.isEmpty ? [turn(false, "hey", at(day: 1))] : turns,
            importantDates: dates, intel: intel, sensitiveOccasion: sensitive, now: now)
    }

    // MARK: Cluster scoring — the headline correctness fix

    @Test("Two triggers in the SAME cluster take the max, they don't stack")
    func sameClusterMax() {
        // Both trajectory-cooling and vibe-cooling in the cooling cluster.
        var turns: [ThreadTurn] = []
        // Build a cooling trajectory: lots of their messages in baseline, few recent.
        for i in 0..<12 { turns.append(turn(false, "hey what's up", at(day: 1 + i))) }
        turns.append(turn(false, "sup", at(day: 40)))
        let now = at(day: 55)
        let coolingModel = RelationshipModel.assemble(
            threadID: UUID(), displayName: "Sam", isGroup: false, personID: nil,
            turns: turns, now: now)
        // If cooling triggers fired and stacked, score would be 50; max keeps it ≤ 25.
        let cands = DecisionGate.evaluate([coolingModel], now: now)
        if let c = cands.first, c.triggers.contains(where: { $0.cluster == .cooling }) {
            let coolingScore = c.triggers.filter { $0.cluster == .cooling }.map(\.score).max()!
            #expect(c.score <= coolingScore + DecisionGate.scoreEffortImbalance + 1)  // cooling counted once
        }
    }

    @Test("clusterScore takes the max within a cluster and sums across clusters")
    func clusterScoreMath() {
        let triggers = [
            DecisionTrigger(cluster: .cooling, kind: "trajectoryCooling", score: 25, evidence: ""),
            DecisionTrigger(cluster: .cooling, kind: "vibeCooling", score: 25, evidence: ""),
            DecisionTrigger(cluster: .date, kind: "upcomingDate", score: 50, evidence: ""),
        ]
        // cooling max (25) + date (50) = 75, NOT 25+25+50=100.
        #expect(DecisionGate.clusterScore(triggers) == 75)
    }

    // MARK: Independent clusters DO stack

    @Test("A real date outscores a busy-week cooling read")
    func dateBeatsCooling() {
        let now = at(day: 10)
        let bday = ImportantDate(id: "b", threadID: UUID(), kind: .birthday, label: "birthday",
                                 month: 6, day: 15, recurring: true, source: .manual)
        let dateModel = model(dates: [bday], now: now)
        let cands = DecisionGate.evaluate([dateModel], now: now)
        #expect(cands.first?.triggers.contains { $0.kind == "upcomingDate" } == true)
        #expect((cands.first?.score ?? 0) >= DecisionGate.scoreUpcomingDate)
    }

    // MARK: Hard suppressors

    @Test("Groups are never candidates")
    func groupsSuppressed() {
        let now = at(day: 10)
        let bday = ImportantDate(id: "b", threadID: UUID(), kind: .birthday, label: "birthday",
                                 month: 6, day: 15, recurring: true, source: .manual)
        let g = model(isGroup: true, dates: [bday], now: now)
        #expect(DecisionGate.evaluate([g], now: now).isEmpty)
    }

    @Test("Automated (bot/newsletter) threads are never candidates")
    func automatedSuppressed() {
        let now = at(day: 10)
        let bday = ImportantDate(id: "b", threadID: UUID(), kind: .birthday, label: "birthday",
                                 month: 6, day: 15, recurring: true, source: .manual)
        let bot = model(dates: [bday], intel: ThreadIntel(automated: true), now: now)
        #expect(DecisionGate.evaluate([bot], now: now).isEmpty)
    }

    @Test("quietUntil in the future suppresses the whole candidate")
    func quietUntilSuppresses() {
        let now = at(day: 10)
        let tid = UUID()
        // June 22 birthday: within the 14-day horizon at both day 10 (12d out)
        // and day 15 (7d out), so the ONLY thing that changes between the two
        // evaluations is the quietUntil window.
        let bday = ImportantDate(id: "b", threadID: tid, kind: .birthday, label: "birthday",
                                 month: 6, day: 22, recurring: true, source: .manual)
        let m = model(threadID: tid, dates: [bday], now: now)
        let supp = DecisionGate.Suppressors(quietUntil: [tid: at(day: 14)])
        #expect(DecisionGate.evaluate([m], now: now, suppressors: supp).isEmpty)
        // Once quietUntil passes (day 15 > day 14), the same model fires again.
        #expect(!DecisionGate.evaluate([m], now: at(day: 15), suppressors: supp).isEmpty)
    }

    @Test("An active inputHash (unchanged state) is not re-billed")
    func inputHashDedup() {
        let now = at(day: 10)
        let bday = ImportantDate(id: "b", threadID: UUID(), kind: .birthday, label: "birthday",
                                 month: 6, day: 15, recurring: true, source: .manual)
        let m = model(dates: [bday], now: now)
        let first = DecisionGate.evaluate([m], now: now)
        #expect(first.count == 1)
        let supp = DecisionGate.Suppressors(activeInputHashes: [first[0].inputHash])
        #expect(DecisionGate.evaluate([m], now: now, suppressors: supp).isEmpty)
    }

    @Test("A NEW inbound message busts the inputHash cache (content freshness)")
    func newMessageBustsHash() {
        let now = at(day: 10)
        let bday = ImportantDate(id: "b", threadID: UUID(), kind: .birthday, label: "birthday",
                                 month: 6, day: 15, recurring: true, source: .manual)
        let tid = UUID()
        let older = model(threadID: tid, turns: [turn(false, "hey", at(day: 1))], dates: [bday], now: now)
        let hash1 = DecisionGate.evaluate([older], now: now).first!.inputHash
        // Same person, but a newer last message → different lastMessageAt → different hash.
        let newer = model(threadID: tid, turns: [turn(false, "hey", at(day: 1)), turn(false, "new msg", at(day: 9))], dates: [bday], now: now)
        let hash2 = DecisionGate.evaluate([newer], now: now).first!.inputHash
        #expect(hash1 != hash2)
    }

    // MARK: Budget + deterministic order

    @Test("The daily budget caps the number of candidates")
    func budgetCaps() {
        let now = at(day: 10)
        let models = (0..<15).map { i -> RelationshipModel in
            let bday = ImportantDate(id: "b\(i)", threadID: UUID(), kind: .birthday,
                                     label: "birthday", month: 6, day: 15, recurring: true, source: .manual)
            return model(threadID: UUID(), name: "P\(i)", dates: [bday], now: now)
        }
        let cands = DecisionGate.evaluate(models, now: now, config: .init(dailyBudget: 5))
        #expect(cands.count == 5)
    }

    @Test("Ties break deterministically by threadID string")
    func deterministicTiebreak() {
        let now = at(day: 10)
        let ids = [UUID(), UUID(), UUID()]
        let models = ids.map { id -> RelationshipModel in
            let bday = ImportantDate(id: "b", threadID: id, kind: .birthday, label: "birthday",
                                     month: 6, day: 15, recurring: true, source: .manual)
            return model(threadID: id, dates: [bday], now: now)
        }
        let a = DecisionGate.evaluate(models, now: now).map(\.threadID)
        let b = DecisionGate.evaluate(models.reversed(), now: now).map(\.threadID)
        #expect(a == b)  // order independent of input order
        #expect(a == ids.sorted { $0.uuidString < $1.uuidString })
    }

    // MARK: Sensitive tier — the safety enforcement

    @Test("A corroborated sensitive occasion about the participant fires the sensitive tier")
    func sensitiveFires() {
        let now = at(day: 10)
        let occ = SensitiveOccasion(kind: .possibleLoss, corroborationCount: 3,
                                    subjectIsParticipant: true, evidence: ["their dad passed away"])
        let m = model(sensitive: occ, now: now)
        let cands = DecisionGate.evaluate([m], now: now)
        #expect(cands.first?.isSensitive == true)
        #expect(cands.first?.triggers.contains { $0.cluster == .sensitive } == true)
    }

    @Test("An under-corroborated sensitive occasion does NOT fire")
    func underCorroboratedSuppressed() {
        let now = at(day: 10)
        let occ = SensitiveOccasion(kind: .possibleLoss, corroborationCount: 1,
                                    subjectIsParticipant: true, evidence: ["maybe a loss?"])
        let m = model(sensitive: occ, now: now)
        let cands = DecisionGate.evaluate([m], now: now)
        #expect(cands.allSatisfy { !$0.isSensitive })
    }

    @Test("A third-party sensitive event (not the participant) does NOT fire")
    func thirdPartySuppressed() {
        let now = at(day: 10)
        let occ = SensitiveOccasion(kind: .possibleLoss, corroborationCount: 3,
                                    subjectIsParticipant: false, evidence: ["their coworker's uncle died"])
        let m = model(sensitive: occ, now: now)
        #expect(DecisionGate.evaluate([m], now: now).allSatisfy { !$0.isSensitive })
    }

    @Test("Heuristic-only candidates are NEVER marked sensitive")
    func heuristicsNeverSensitive() {
        let now = at(day: 10)
        let bday = ImportantDate(id: "b", threadID: UUID(), kind: .birthday, label: "birthday",
                                 month: 6, day: 15, recurring: true, source: .manual)
        let m = model(dates: [bday], now: now)   // date + maybe cooling, but no sensitiveOccasion
        #expect(DecisionGate.evaluate([m], now: now).allSatisfy { !$0.isSensitive })
    }
}
