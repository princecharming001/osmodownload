import Foundation
import GRDB

/// The local store API over the encrypted GRDB database. Owns device-sequence
/// allocation and change-aware upserts (an unchanged row keeps its `updatedAt`/
/// `deviceSeq`, so re-ingesting a thread doesn't churn the future sync oplog),
/// plus unified FTS search across every platform's messages.
public final class OsmoStore: @unchecked Sendable {
    private let dbQueue: DatabaseQueue
    /// This Mac's stable identity (persisted once), stamped into future sync ops.
    public let deviceID: UUID

    public init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        self.deviceID = try dbQueue.write { db in try Self.loadOrCreateDevice(db) }
    }

    public convenience init(url: URL, passphrase: String? = nil) throws {
        try self.init(dbQueue: OsmoDatabase.open(at: url, passphrase: passphrase))
    }

    public static func inMemory() throws -> OsmoStore {
        try OsmoStore(dbQueue: OsmoDatabase.openInMemory())
    }

    // MARK: Device + sequence

    private static func loadOrCreateDevice(_ db: Database) throws -> UUID {
        if let idString = try String.fetchOne(db, sql: "SELECT id FROM device LIMIT 1"),
           let id = UUID(uuidString: idString) {
            return id
        }
        let id = UUID()
        try db.execute(sql: "INSERT INTO device (id, seq) VALUES (?, 0)",
                       arguments: [id.uuidString])
        return id
    }

    /// Allocate the next monotonic device sequence inside the current transaction.
    private func nextSeq(_ db: Database) throws -> Int64 {
        try db.execute(sql: "UPDATE device SET seq = seq + 1")
        return try Int64.fetchOne(db, sql: "SELECT seq FROM device LIMIT 1") ?? 0
    }

    // MARK: Ingest (change-aware upsert)

    /// Insert or update a platform-sourced record. If a row with the same id
    /// already exists and its content is byte-identical (ignoring sync metadata),
    /// nothing is written — so unchanged re-ingests are free and don't advance the
    /// sync clock. When content differs (or the row is new), it's saved with a
    /// fresh `updatedAt` + allocated `deviceSeq`.
    @discardableResult
    public func ingest<R>(_ record: R) throws -> Bool
    where R: SyncableRecord & FetchableRecord & PersistableRecord & TableRecord
             & Identifiable & Equatable, R.ID == UUID {
        try dbQueue.write { db in
            let existing = try R.fetchOne(db, id: record.id)
            if let existing {
                // Compare content by neutralizing sync metadata.
                var candidate = record
                candidate.sync = existing.sync
                if candidate == existing { return false }   // unchanged → skip
            }
            var toSave = record
            toSave.sync = SyncMeta(id: record.id, updatedAt: Date(),
                                   deviceSeq: try nextSeq(db), deletedAt: record.sync.deletedAt)
            try toSave.save(db)
            return true
        }
    }

    /// Soft-delete (tombstone) by id — never a hard DELETE, so the removal can
    /// propagate through the append-only sync log.
    public func softDelete<R>(_ type: R.Type, id: UUID) throws
    where R: SyncableRecord & FetchableRecord & PersistableRecord & TableRecord
             & Identifiable, R.ID == UUID {
        try dbQueue.write { db in
            guard var row = try R.fetchOne(db, id: id) else { return }
            row.sync = SyncMeta(id: id, updatedAt: Date(), deviceSeq: try nextSeq(db),
                                deletedAt: Date())
            try row.save(db)
        }
    }

    // MARK: Fetch

    public func thread(id: UUID) throws -> OsmoThread? {
        try dbQueue.read { db in try OsmoThread.fetchOne(db, id: id) }
    }

    public func messages(inThread threadID: UUID) throws -> [OsmoMessage] {
        try dbQueue.read { db in
            try OsmoMessage
                .filter(Column("threadID") == threadID)
                .filter(Column("deletedAt") == nil)
                .order(Column("sentAt"))
                .fetchAll(db)
        }
    }

    public func messageCount() throws -> Int {
        try dbQueue.read { db in
            try OsmoMessage.filter(Column("deletedAt") == nil).fetchCount(db)
        }
    }

    public func threadCount() throws -> Int {
        try dbQueue.read { db in
            try OsmoThread.filter(Column("deletedAt") == nil).fetchCount(db)
        }
    }

    // MARK: Unified search (FTS5)

    /// Full-text search across every platform's messages, newest first. Live
    /// (non-tombstoned) rows only. `query` is an FTS5 MATCH expression; callers
    /// pass user text (see `sanitizeFTS`).
    public func search(_ query: String, limit: Int = 50) throws -> [OsmoMessage] {
        let match = Self.sanitizeFTS(query)
        guard !match.isEmpty else { return [] }
        return try dbQueue.read { db in
            try OsmoMessage.fetchAll(db, sql: """
                SELECT message.* FROM message
                JOIN message_ft ON message_ft.rowid = message.rowid
                WHERE message_ft MATCH ?
                  AND message.deletedAt IS NULL
                ORDER BY message.sentAt DESC
                LIMIT ?
                """, arguments: [match, limit])
        }
    }

    /// Turn arbitrary user text into a safe FTS5 prefix query (quote each token,
    /// add `*` for prefix matching), avoiding MATCH-syntax errors on punctuation.
    static func sanitizeFTS(_ text: String) -> String {
        let tokens = text
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return "" }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }
}
