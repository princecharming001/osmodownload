import Foundation
import GRDB

// Consumer-shell persistence: per-thread drafts, snoozes, the offline send
// queue, whole-store JSON export, and delete-all. Device-local UX state — not
// synced entities, so no SyncMeta columns (see the v5 migration).

public struct ThreadDraft: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public var threadID: UUID
    public var text: String
    public var updatedAt: Date
    public static let databaseTableName = "thread_draft"
    public init(threadID: UUID, text: String, updatedAt: Date = Date()) {
        self.threadID = threadID; self.text = text; self.updatedAt = updatedAt
    }
}

public struct ThreadSnooze: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public var threadID: UUID
    public var until: Date
    public static let databaseTableName = "thread_snooze"
    public init(threadID: UUID, until: Date) { self.threadID = threadID; self.until = until }
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

    /// Empty text clears the draft.
    public func saveDraft(_ text: String, forThread threadID: UUID) throws {
        try dbQueue.write { db in
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = try ThreadDraft.deleteOne(db, key: threadID)
            } else {
                try ThreadDraft(threadID: threadID, text: text).save(db)
            }
        }
    }

    // MARK: - Snoozes

    public func snooze(thread threadID: UUID, until: Date) throws {
        try dbQueue.write { db in try ThreadSnooze(threadID: threadID, until: until).save(db) }
    }

    public func unsnooze(thread threadID: UUID) throws {
        _ = try dbQueue.write { db in try ThreadSnooze.deleteOne(db, key: threadID) }
    }

    /// Threads snoozed past `now` (hidden from queue/inbox until due).
    public func snoozedThreadIDs(now: Date = Date()) throws -> Set<UUID> {
        try dbQueue.read { db in
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
        }
        let export = try dbQueue.read { db in
            Export(exportedAt: Date(),
                   contacts: try OsmoContact.fetchAll(db),
                   threads: try OsmoThread.fetchAll(db),
                   messages: try OsmoMessage.fetchAll(db),
                   people: try Person.fetchAll(db),
                   memories: try RelationshipMemory.fetchAll(db),
                   projects: try Project.fetchAll(db))
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
            try db.execute(sql: "DELETE FROM message")
            try db.execute(sql: "DELETE FROM thread")
            try db.execute(sql: "DELETE FROM contact")
            try db.execute(sql: "DELETE FROM person")
            try db.execute(sql: "DELETE FROM relationship_memory")
            try db.execute(sql: "DELETE FROM project")
        }
    }
}
