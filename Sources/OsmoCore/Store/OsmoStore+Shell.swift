import Foundation
import GRDB

// Consumer-shell persistence: per-thread drafts, snoozes, the offline send
// queue, whole-store JSON export, and delete-all. Device-local UX state — not
// synced entities, so no SyncMeta columns (see the v5 migration).

public struct ThreadDraft: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public var threadID: UUID
    public var text: String
    public var updatedAt: Date
    /// True when Osmo wrote this draft itself (autodraft-on-arrival), never the
    /// user. The never-overwrite-user-text rule reads this flag, not a text
    /// marker (a prefix could leak into what actually gets sent).
    public var isAuto: Bool = false
    public static let databaseTableName = "thread_draft"
    public init(threadID: UUID, text: String, updatedAt: Date = Date(), isAuto: Bool = false) {
        self.threadID = threadID; self.text = text; self.updatedAt = updatedAt; self.isAuto = isAuto
    }
}

public struct ThreadSnooze: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public var threadID: UUID
    public var until: Date
    public static let databaseTableName = "thread_snooze"
    public init(threadID: UUID, until: Date) { self.threadID = threadID; self.until = until }
}

/// "Nudge me if no reply" — a per-thread follow-up reminder. `setAt` marks when
/// it was armed so an inbound reply AFTER arming auto-clears it (they answered;
/// nothing to chase).
public struct ThreadFollowup: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public var threadID: UUID
    public var due: Date
    public var setAt: Date
    public static let databaseTableName = "thread_followup"
    public init(threadID: UUID, due: Date, setAt: Date = Date()) {
        self.threadID = threadID; self.due = due; self.setAt = setAt
    }
}

public struct QueuedSend: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord, Identifiable {
    public var id: Int64?
    public var platform: Platform
    public var platformThreadID: String
    public var text: String
    public var queuedAt: Date
    public var attempts: Int
    public static let databaseTableName = "send_queue"
    public init(id: Int64? = nil, platform: Platform, platformThreadID: String,
                text: String, queuedAt: Date = Date(), attempts: Int = 0) {
        self.id = id; self.platform = platform; self.platformThreadID = platformThreadID
        self.text = text; self.queuedAt = queuedAt; self.attempts = attempts
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension OsmoStore {

    // MARK: - Drafts

    public func draft(forThread threadID: UUID) throws -> String? {
        try dbQueue.read { db in
            try ThreadDraft.fetchOne(db, key: threadID)?.text
        }
    }

    /// The full record — callers that need to know whether the saved draft was
    /// Osmo's own autodraft (vs. user-typed) read this instead of `draft(forThread:)`.
    public func draftRecord(forThread threadID: UUID) throws -> ThreadDraft? {
        try dbQueue.read { db in try ThreadDraft.fetchOne(db, key: threadID) }
    }

    /// Empty text clears the draft. `isAuto` defaults false — every existing
    /// (user-authored) call site keeps writing `isAuto: false` unchanged, which
    /// is exactly the desired behavior: a real user save always clears the flag.
    public func saveDraft(_ text: String, forThread threadID: UUID, isAuto: Bool = false) throws {
        try dbQueue.write { db in
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = try ThreadDraft.deleteOne(db, key: threadID)
            } else {
                try ThreadDraft(threadID: threadID, text: text, isAuto: isAuto).save(db)
            }
        }
    }

    // MARK: - Snoozes

    /// Ground-truth group inference: a messaging thread where 2+ DISTINCT
    /// people (besides the user) have sent messages is a group, whatever the
    /// provider's chat payload claimed (Unipile's `type` field burned us —
    /// every IG group imported as a 1:1 and grew a person profile page).
    /// Email is excluded: multi-sender email threads are normal threading,
    /// not "group chats". Returns how many threads were flipped.
    @discardableResult
    public func repairGroupFlags() throws -> Int {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE thread SET isGroup = 1
                WHERE isGroup = 0 AND deletedAt IS NULL
                  AND platform IN ('imessage','whatsapp','instagram','linkedin','x')
                  AND id IN (SELECT threadID FROM message
                             WHERE isFromMe = 0 AND senderContactID IS NOT NULL
                               AND deletedAt IS NULL
                             GROUP BY threadID
                             HAVING COUNT(DISTINCT senderContactID) >= 2)
                """)
            return db.changesCount
        }
    }

    public func snooze(thread threadID: UUID, until: Date) throws {
        try dbQueue.write { db in try ThreadSnooze(threadID: threadID, until: until).save(db) }
    }

    public func unsnooze(thread threadID: UUID) throws {
        _ = try dbQueue.write { db in try ThreadSnooze.deleteOne(db, key: threadID) }
    }

    /// Threads snoozed past `now` (hidden from queue/inbox until due).
    /// A `write` transaction, not `read`: the auto-clear DELETE below would
    /// throw SQLITE_READONLY inside GRDB's read-only `read` block, making this
    /// call fail outright the moment any snooze elapsed.
    public func snoozedThreadIDs(now: Date = Date()) throws -> Set<UUID> {
        try dbQueue.write { db in
            let due = try ThreadSnooze.filter(Column("until") <= now).fetchAll(db)
            // Auto-clear elapsed snoozes on read.
            for snooze in due { _ = try ThreadSnooze.deleteOne(db, key: snooze.threadID) }
            let active = try ThreadSnooze.fetchAll(db)
            return Set(active.map(\.threadID))
        }
    }

    /// Snoozes that just became due (for the notifier), then cleared.
    public func dueSnoozes(now: Date = Date()) throws -> [ThreadSnooze] {
        try dbQueue.write { db in
            let due = try ThreadSnooze.filter(Column("until") <= now).fetchAll(db)
            for snooze in due { _ = try ThreadSnooze.deleteOne(db, key: snooze.threadID) }
            return due
        }
    }

    // MARK: - Follow-up reminders ("nudge me if no reply")

    public func setFollowup(thread threadID: UUID, due: Date, now: Date = Date()) throws {
        try dbQueue.write { db in
            try ThreadFollowup(threadID: threadID, due: due, setAt: now).save(db)
        }
    }

    public func clearFollowup(thread threadID: UUID) throws {
        _ = try dbQueue.write { db in try ThreadFollowup.deleteOne(db, key: threadID) }
    }

    public func followup(forThread threadID: UUID) throws -> ThreadFollowup? {
        try dbQueue.read { db in try ThreadFollowup.fetchOne(db, key: threadID) }
    }

    /// All armed follow-ups, auto-clearing any the other person already answered
    /// (an inbound message after `setAt` means the nudge is moot). Returns the
    /// still-armed ones; the caller splits due vs pending by `due <= now`.
    public func activeFollowups(now: Date = Date()) throws -> [ThreadFollowup] {
        try dbQueue.write { db in
            let all = try ThreadFollowup.fetchAll(db)
            var live: [ThreadFollowup] = []
            for f in all {
                let answered = try OsmoMessage
                    .filter(Column("threadID") == f.threadID)
                    .filter(Column("isFromMe") == false)
                    .filter(Column("deletedAt") == nil)
                    .filter(Column("sentAt") > f.setAt)
                    .fetchCount(db) > 0
                if answered { _ = try ThreadFollowup.deleteOne(db, key: f.threadID) }
                else { live.append(f) }
            }
            return live.sorted { $0.due < $1.due }
        }
    }

    // MARK: - Offline send queue

    public func enqueueSend(_ send: QueuedSend) throws {
        try dbQueue.write { db in var s = send; try s.insert(db) }
    }

    public func queuedSends() throws -> [QueuedSend] {
        try dbQueue.read { db in
            try QueuedSend.order(Column("queuedAt").asc).fetchAll(db)
        }
    }

    public func dequeueSend(id: Int64) throws {
        _ = try dbQueue.write { db in try QueuedSend.deleteOne(db, key: id) }
    }

    public func bumpSendAttempt(id: Int64) throws {
        try dbQueue.write { db in
            if var send = try QueuedSend.fetchOne(db, key: id) {
                send.attempts += 1
                try send.update(db)
            }
        }
    }

    // MARK: - Person enrichment (public-profile cache)

    public func enrichment(forPerson personID: UUID) throws -> PersonEnrichment? {
        try dbQueue.read { db in try PersonEnrichment.fetchOne(db, key: personID) }
    }

    /// Bulk load for reload() — list subtitles + Ask read this with zero network.
    public func enrichments() throws -> [PersonEnrichment] {
        try dbQueue.read { db in try PersonEnrichment.fetchAll(db) }
    }

    public func upsertEnrichment(_ enrichment: PersonEnrichment) throws {
        try dbQueue.write { db in try enrichment.save(db) }
    }

    public func deleteEnrichment(forPerson personID: UUID) throws {
        _ = try dbQueue.write { db in try PersonEnrichment.deleteOne(db, key: personID) }
    }

    /// The Privacy pane's "clear fetched profiles" button.
    public func deleteAllEnrichments() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM person_enrichment")
        }
    }

    // MARK: - Export + delete-all

    /// Whole-store JSON export (user-owned data; no key material, no tokens).
    public func exportJSON() throws -> Data {
        struct Export: Codable {
            var exportedAt: Date
            var contacts: [OsmoContact]
            var threads: [OsmoThread]
            var messages: [OsmoMessage]
            var people: [Person]
            var memories: [RelationshipMemory]
            var projects: [Project]
            var enrichments: [PersonEnrichment]
        }
        let export = try dbQueue.read { db in
            Export(exportedAt: Date(),
                   contacts: try OsmoContact.fetchAll(db),
                   threads: try OsmoThread.fetchAll(db),
                   messages: try OsmoMessage.fetchAll(db),
                   people: try Person.fetchAll(db),
                   memories: try RelationshipMemory.fetchAll(db),
                   projects: try Project.fetchAll(db),
                   enrichments: try PersonEnrichment.fetchAll(db))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(export)
    }

    /// Erase every row (messages, people, memory, projects, drafts, queue) but
    /// keep the schema. The caller (app layer) additionally clears Keychain
    /// keys + resets the onboarding flag for a true fresh-install state.
    public func deleteAllData() throws {
        try dbQueue.write { db in
            // Order respects FKs; device row stays (fresh clock is fine).
            try db.execute(sql: "DELETE FROM send_queue")
            try db.execute(sql: "DELETE FROM thread_snooze")
            try db.execute(sql: "DELETE FROM thread_draft")
            try db.execute(sql: "DELETE FROM person_enrichment")
            try db.execute(sql: "DELETE FROM message")
            try db.execute(sql: "DELETE FROM thread")
            try db.execute(sql: "DELETE FROM contact")
            try db.execute(sql: "DELETE FROM person")
            try db.execute(sql: "DELETE FROM relationship_memory")
            try db.execute(sql: "DELETE FROM project")
        }
    }
}
