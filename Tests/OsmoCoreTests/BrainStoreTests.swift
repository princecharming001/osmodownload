import Testing
import Foundation
import GRDB
@testable import OsmoCore

@Suite("Brain context store — vibe samples + important dates (v15)")
struct BrainStoreTests {
    func newStore() throws -> OsmoStore { try OsmoStore.inMemory() }
    let cal = Calendar.current
    func at(day: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 6, day: day))! }

    // MARK: Migration

    @Test("v15 creates vibe_sample and important_date with their indexes")
    func migrationCreatesTables() throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        try OsmoDatabase.migrator.migrate(queue)
        let tables = try queue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'"))
        }
        #expect(tables.contains("vibe_sample"))
        #expect(tables.contains("important_date"))
        let indexes = try queue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='index'"))
        }
        #expect(indexes.contains("idx_vibe_sample_thread_time"))
        #expect(indexes.contains("idx_important_date_thread"))
    }

    @Test("An existing pre-v15 store upgrades cleanly and gains the tables")
    func existingStoreUpgrades() throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        try OsmoDatabase.migrator.migrate(queue, upTo: "v14-send-idempotency")
        let before = try queue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'"))
        }
        #expect(!before.contains("vibe_sample"))
        try OsmoDatabase.migrator.migrate(queue)
        let after = try queue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'"))
        }
        #expect(after.contains("vibe_sample"))
        #expect(after.contains("important_date"))
    }

    // MARK: Vibe samples

    @Test("Vibe samples append and read back oldest → newest")
    func vibeRoundTrip() throws {
        let store = try newStore()
        let thread = UUID()
        try store.appendVibeSample(.init(threadID: thread, sampledAt: at(day: 3), score: 0.2, source: .keywordSentiment))
        try store.appendVibeSample(.init(threadID: thread, sampledAt: at(day: 1), score: -0.5, source: .llmTemperature))
        try store.appendVibeSample(.init(threadID: thread, sampledAt: at(day: 2), score: 0.0, source: .keywordSentiment))
        let samples = try store.vibeSamples(forThread: thread)
        #expect(samples.count == 3)
        #expect(samples.map(\.score) == [-0.5, 0.0, 0.2])  // ordered by sampledAt
    }

    @Test("Score is clamped to [-1, 1] on the way in")
    func vibeClamps() throws {
        let store = try newStore()
        let thread = UUID()
        try store.appendVibeSample(.init(threadID: thread, sampledAt: at(day: 1), score: 5.0, source: .keywordSentiment))
        #expect(try store.vibeSamples(forThread: thread).first?.score == 1.0)
    }

    @Test("Prune keeps only the most recent N samples")
    func vibePrune() throws {
        let store = try newStore()
        let thread = UUID()
        for d in 1...10 {
            try store.appendVibeSample(.init(threadID: thread, sampledAt: at(day: d), score: 0.1, source: .keywordSentiment))
        }
        try store.pruneVibeSamples(forThread: thread, keep: 4)
        let kept = try store.vibeSamples(forThread: thread)
        #expect(kept.count == 4)
        #expect(kept.map { cal.component(.day, from: $0.sampledAt) } == [7, 8, 9, 10])
    }

    // MARK: Important dates

    @Test("Important dates upsert idempotently on the deterministic id")
    func dateDedup() throws {
        let store = try newStore()
        let thread = UUID()
        let id = ImportantDate.makeID(threadID: thread, kind: .birthday, date: nil, month: 3, day: 14)
        try store.upsertImportantDate(.init(id: id, threadID: thread, kind: .birthday,
                                            label: "Sarah's birthday", month: 3, day: 14,
                                            recurring: true, source: .regex))
        // Same birthday, now from a manual entry — overwrites, stays one row.
        try store.upsertImportantDate(.init(id: id, threadID: thread, kind: .birthday,
                                            label: "Sarah's birthday", month: 3, day: 14,
                                            recurring: true, source: .manual))
        let dates = try store.importantDates(forThread: thread)
        #expect(dates.count == 1)
        #expect(dates.first?.source == .manual)
    }

    @Test("Upcoming recurring birthday within the window is found; one far away is not")
    func upcomingRecurring() throws {
        let store = try newStore()
        let thread = UUID()
        let now = at(day: 10)  // June 10
        // Birthday June 20 → within a 30-day window.
        try store.upsertImportantDate(.init(
            id: "a", threadID: thread, kind: .birthday, label: "soon", month: 6, day: 20,
            recurring: true, source: .regex))
        // Birthday Dec 25 → outside a 30-day window.
        try store.upsertImportantDate(.init(
            id: "b", threadID: thread, kind: .birthday, label: "far", month: 12, day: 25,
            recurring: true, source: .regex))
        let upcoming = try store.upcomingImportantDates(within: 30 * 86_400, now: now)
        #expect(upcoming.map(\.id) == ["a"])
    }

    // MARK: Relationship decisions (v16)

    func decision(_ threadID: UUID, hash: String, status: StoredDecisionStatus = .fresh,
                  expiresAt: Date) -> StoredDecision {
        StoredDecision(id: StoredDecision.makeID(threadID: threadID, inputHash: hash),
                       threadID: threadID, kind: "reachOut", move: "say hi", confidence: 0.7,
                       evidence: ["they're overdue"], inputHash: hash, isSensitive: false,
                       status: status, expiresAt: expiresAt)
    }

    @Test("v16 creates the relationship_decision table and indexes")
    func v16Migration() throws {
        var config = Configuration(); config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        try OsmoDatabase.migrator.migrate(queue)
        let names = try queue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master"))
        }
        #expect(names.contains("relationship_decision"))
        #expect(names.contains("idx_decision_status"))
    }

    @Test("Decisions upsert, round-trip evidence as JSON, and filter by status")
    func decisionRoundTrip() throws {
        let store = try newStore()
        let tid = UUID()
        try store.upsertDecision(decision(tid, hash: "h1", expiresAt: at(day: 20)))
        let all = try store.decisions()
        #expect(all.count == 1)
        #expect(all.first?.evidence == ["they're overdue"])
        #expect(try store.decisions(status: .surfaced).isEmpty)
        #expect(try store.decision(forThread: tid)?.inputHash == "h1")
    }

    @Test("Status transitions persist")
    func decisionStatus() throws {
        let store = try newStore()
        let tid = UUID()
        let d = decision(tid, hash: "h1", expiresAt: at(day: 20))
        try store.upsertDecision(d)
        try store.setDecisionStatus(id: d.id, .acted)
        #expect(try store.decision(forThread: tid)?.status == .acted)
    }

    @Test("expireDecisions flips only past-TTL fresh/surfaced rows to expired")
    func expireDecisionsTest() throws {
        let store = try newStore()
        let t1 = UUID(), t2 = UUID(), t3 = UUID()
        try store.upsertDecision(decision(t1, hash: "a", status: .fresh, expiresAt: at(day: 5)))
        try store.upsertDecision(decision(t2, hash: "b", status: .surfaced, expiresAt: at(day: 30)))
        try store.upsertDecision(decision(t3, hash: "c", status: .acted, expiresAt: at(day: 1)))
        let n = try store.expireDecisions(now: at(day: 10))
        #expect(n == 1)
        #expect(try store.decision(forThread: t1)?.status == .expired)
        #expect(try store.decision(forThread: t2)?.status == .surfaced)
        #expect(try store.decision(forThread: t3)?.status == .acted)
    }

    @Test("activeDecisionInputHashes covers every non-expired state (so a dismissed decision can't resurrect)")
    func activeHashes() throws {
        let store = try newStore()
        try store.upsertDecision(decision(UUID(), hash: "fresh1", status: .fresh, expiresAt: at(day: 20)))
        try store.upsertDecision(decision(UUID(), hash: "surf1", status: .surfaced, expiresAt: at(day: 20)))
        try store.upsertDecision(decision(UUID(), hash: "acted1", status: .acted, expiresAt: at(day: 20)))
        try store.upsertDecision(decision(UUID(), hash: "dismissed1", status: .dismissed, expiresAt: at(day: 20)))
        try store.upsertDecision(decision(UUID(), hash: "expired1", status: .expired, expiresAt: at(day: 1)))
        // Everything except the expired one — an acted/dismissed state stays
        // suppressed so the same suggestion never comes back for the same state.
        #expect(try store.activeDecisionInputHashes() == ["fresh1", "surf1", "acted1", "dismissed1"])
    }

    // MARK: Feedback outcomes (v17) + decision family (v18)

    @Test("v17/v18 create the outcome table and the decision.family column")
    func v17v18Migration() throws {
        var config = Configuration(); config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        try OsmoDatabase.migrator.migrate(queue)
        let tables = try queue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'"))
        }
        #expect(tables.contains("suggestion_outcome"))
        let cols = try queue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(relationship_decision)").map { $0["name"] as String }
        }
        #expect(cols.contains("family"))
    }

    @Test("Outcomes record and read back per person, time-windowed")
    func outcomeRoundTrip() throws {
        let store = try newStore()
        let person = UUID()
        try store.recordOutcome(.init(decisionID: "d1", threadID: UUID(), personID: person,
                                      decisionKind: "reachOut", family: "silence", outcome: .acted,
                                      createdAt: at(day: 5)))
        try store.recordOutcome(.init(decisionID: "d2", threadID: UUID(), personID: person,
                                      decisionKind: "gesture", gestureKind: "birthday", family: "date",
                                      outcome: .dismissedSeen, createdAt: at(day: 1)))
        let recent = try store.outcomes(personID: person, since: at(day: 3))
        #expect(recent.count == 1)          // only the day-5 one is within the window
        #expect(recent.first?.outcome == .acted)
        #expect(try store.recentOutcomes(since: at(day: 0)).count == 2)
    }

    @Test("nextOccurrence rolls a passed recurring date to next year")
    func nextOccurrenceRolls() throws {
        let jan1 = ImportantDate(id: "x", threadID: UUID(), kind: .birthday, label: "y",
                                 month: 1, day: 1, recurring: true, source: .regex)
        let june = at(day: 10)
        let next = jan1.nextOccurrence(after: june)!
        #expect(cal.component(.year, from: next) == 2027)  // Jan already passed in 2026
        #expect(cal.component(.month, from: next) == 1)
    }
}
