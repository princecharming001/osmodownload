import Foundation
import GRDB

/// Store access for the Relationship Brain context layers (W3). VibeSample is an
/// append-only time series; ImportantDate is deduped-upsert reference data.
/// Everything here is device-local — no sync-clock advance, no oplog.
public extension OsmoStore {

    // MARK: Vibe samples (time series)

    /// Append a vibe reading. Append-only — the series IS the history.
    func appendVibeSample(_ sample: VibeSample) throws {
        try dbQueue.write { db in var s = sample; try s.insert(db) }
    }

    /// The full vibe series for a thread, oldest → newest.
    func vibeSamples(forThread threadID: UUID) throws -> [VibeSample] {
        try dbQueue.read { db in
            try VibeSample
                .filter(Column("threadID") == threadID)
                .order(Column("sampledAt").asc)
                .fetchAll(db)
        }
    }

    /// Trim a thread's series to its most recent `keep` samples — the trend only
    /// ever looks at a recent window, so unbounded growth buys nothing.
    func pruneVibeSamples(forThread threadID: UUID, keep: Int = 200) throws {
        try dbQueue.write { db in
            let ids = try VibeSample
                .filter(Column("threadID") == threadID)
                .order(Column("sampledAt").desc)
                .fetchAll(db)
                .compactMap(\.id)
            let toDelete = Array(ids.dropFirst(keep))
            guard !toDelete.isEmpty else { return }
            _ = try VibeSample.deleteAll(db, keys: toDelete)
        }
    }

    // MARK: Important dates (deduped reference data)

    /// Insert or update a date. Idempotent on the deterministic `id` — the same
    /// birthday captured twice stays one row (a manual entry overwrites a regex one).
    func upsertImportantDate(_ date: ImportantDate) throws {
        try dbQueue.write { db in try date.save(db) }
    }

    func importantDates(forThread threadID: UUID) throws -> [ImportantDate] {
        try dbQueue.read { db in
            try ImportantDate
                .filter(Column("threadID") == threadID)
                .order(Column("createdAt").asc)
                .fetchAll(db)
        }
    }

    func importantDates(personID: UUID) throws -> [ImportantDate] {
        try dbQueue.read { db in
            try ImportantDate.filter(Column("personID") == personID).fetchAll(db)
        }
    }

    func deleteImportantDate(id: String) throws {
        _ = try dbQueue.write { db in try ImportantDate.deleteOne(db, key: id) }
    }

    /// Dates coming up within `window` from `now`. One-off dates match on their
    /// absolute date; recurring month/day dates match on the next occurrence.
    func upcomingImportantDates(within window: TimeInterval,
                                now: Date = Date(),
                                calendar: Calendar = .current) throws -> [ImportantDate] {
        let all = try dbQueue.read { db in try ImportantDate.fetchAll(db) }
        let horizon = now.addingTimeInterval(window)
        return all.filter { d in
            if let next = d.nextOccurrence(after: now, calendar: calendar) {
                return next >= now && next <= horizon
            }
            return false
        }
    }

    // MARK: Relationship decisions (shadow-mode persistence)

    /// Insert or replace a decision (keyed by its deterministic id). One live
    /// decision per (thread, input state).
    func upsertDecision(_ decision: StoredDecision) throws {
        try dbQueue.write { db in try decision.save(db) }
    }

    func decisions(status: StoredDecisionStatus? = nil) throws -> [StoredDecision] {
        try dbQueue.read { db in
            var q = StoredDecision.all()
            if let status { q = q.filter(Column("status") == status.rawValue) }
            return try q.order(Column("createdAt").desc).fetchAll(db)
        }
    }

    func decision(forThread threadID: UUID) throws -> StoredDecision? {
        try dbQueue.read { db in
            try StoredDecision.filter(Column("threadID") == threadID)
                .order(Column("createdAt").desc).fetchOne(db)
        }
    }

    func decisionByID(_ id: String) throws -> StoredDecision? {
        try dbQueue.read { db in try StoredDecision.fetchOne(db, key: id) }
    }

    /// Live decisions (fresh/surfaced) whose TTL has passed — the ones about to
    /// expire, so the caller can record the right feedback outcome first.
    func staleDecisions(now: Date = Date()) throws -> [StoredDecision] {
        try dbQueue.read { db in
            try StoredDecision
                .filter(["fresh", "surfaced"].contains(Column("status")))
                .filter(Column("expiresAt") < now)
                .fetchAll(db)
        }
    }

    func setDecisionStatus(id: String, _ status: StoredDecisionStatus) throws {
        try dbQueue.write { db in
            if var d = try StoredDecision.fetchOne(db, key: id) {
                d.status = status
                try d.update(db)
            }
        }
    }

    /// Flip still-fresh/surfaced decisions to `.expired` once their TTL passes.
    /// Expiry is NEUTRAL — the feedback loop must never read it as a rejection.
    @discardableResult
    func expireDecisions(now: Date = Date()) throws -> Int {
        try dbQueue.write { db in
            let stale = try StoredDecision
                .filter(["fresh", "surfaced"].contains(Column("status")))
                .filter(Column("expiresAt") < now)
                .fetchAll(db)
            for var d in stale { d.status = .expired; try d.update(db) }
            return stale.count
        }
    }

    /// inputHashes of decisions the user has already been given for this exact
    /// state — the gate's dedup set. Includes acted/dismissed as well as
    /// fresh/surfaced, so a suggestion the user already acted on or dismissed
    /// does NOT regenerate (and resurrect) while the conversation state is
    /// unchanged. Only `.expired` (aged out) states are allowed to re-bill.
    func activeDecisionInputHashes() throws -> Set<String> {
        try dbQueue.read { db in
            let rows = try StoredDecision
                .filter(Column("status") != "expired")
                .fetchAll(db)
            return Set(rows.map(\.inputHash))
        }
    }

    // MARK: Feedback outcomes (learning telemetry)

    func recordOutcome(_ outcome: SuggestionOutcome) throws {
        try dbQueue.write { db in var o = outcome; try o.insert(db) }
    }

    /// A person's outcome history within the trailing window (learning has a
    /// 60-day memory; older signal has mean-reverted away anyway).
    func outcomes(personID: UUID, since: Date) throws -> [SuggestionOutcome] {
        try dbQueue.read { db in
            try SuggestionOutcome
                .filter(Column("personID") == personID)
                .filter(Column("createdAt") >= since)
                .order(Column("createdAt").asc)
                .fetchAll(db)
        }
    }

    /// All recent outcomes (for the global decision budget's act-rate).
    func recentOutcomes(since: Date) throws -> [SuggestionOutcome] {
        try dbQueue.read { db in
            try SuggestionOutcome
                .filter(Column("createdAt") >= since)
                .order(Column("createdAt").asc)
                .fetchAll(db)
        }
    }
}

public extension ImportantDate {
    /// The next time this date lands on or after `from`. Recurring month/day
    /// dates roll to this year or next; one-off dates return their absolute date
    /// only if it hasn't already passed.
    func nextOccurrence(after from: Date, calendar: Calendar = .current) -> Date? {
        if recurring, let month, let day {
            var comps = DateComponents()
            comps.month = month
            comps.day = day
            let year = calendar.component(.year, from: from)
            for candidateYear in [year, year + 1] {
                comps.year = candidateYear
                if let d = calendar.date(from: comps), d >= calendar.startOfDay(for: from) {
                    return d
                }
            }
            return nil
        }
        if let date, date >= from { return date }
        return nil
    }
}
