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
