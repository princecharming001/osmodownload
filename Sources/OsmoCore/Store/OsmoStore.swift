import Foundation
import GRDB

/// The local store API over the encrypted GRDB database. Owns device-sequence
/// allocation and change-aware upserts (an unchanged row keeps its `updatedAt`/
/// `deviceSeq`, so re-ingesting a thread doesn't churn the future sync oplog),
/// plus unified FTS search across every platform's messages.
public final class OsmoStore: @unchecked Sendable {
    let dbQueue: DatabaseQueue   // internal: the sync extension reads/writes it
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
            // Carry forward store-owned enrichment (e.g. a contact's identity link)
            // so a reader re-ingest never clobbers it.
            let incoming = existing.map { record.preservingEnrichment(from: $0) } ?? record
            if let existing {
                var candidate = incoming
                candidate.sync = existing.sync              // neutralize sync meta for compare
                if candidate == existing { return false }   // unchanged → skip
            }
            var toSave = incoming
            toSave.sync = SyncMeta(id: record.id, updatedAt: Date(),
                                   deviceSeq: try nextSeq(db), deletedAt: record.sync.deletedAt)
            try toSave.save(db)
            return true
        }
    }

    /// Write a user-authored record (memory, project), always stamping a fresh
    /// sync clock. Unlike `ingest` (reader dedup), this is for deliberate user
    /// edits, which should always advance the clock so they win LWW + sync out.
    public func put<R>(_ record: R) throws
    where R: SyncableRecord & PersistableRecord {
        try dbQueue.write { db in
            var r = record
            r.sync = SyncMeta(id: record.sync.id, updatedAt: Date(),
                              deviceSeq: try nextSeq(db), deletedAt: record.sync.deletedAt)
            try r.save(db)
        }
    }

    // MARK: Memory + Projects

    /// Durable memory for a person (empty default when none saved).
    public func memory(forPerson personID: UUID) throws -> RelationshipMemory {
        try dbQueue.read { db in
            try RelationshipMemory.fetchOne(db, id: personID)
        } ?? RelationshipMemory(personID: personID)
    }

    public func projects(forPerson personID: UUID) throws -> [Project] {
        try dbQueue.read { db in
            try Project.filter(Column("personID") == personID)
                .filter(Column("deletedAt") == nil)
                .order(Column("createdAt").desc)
                .fetchAll(db)
        }
    }

    public func activeProjects() throws -> [Project] {
        try dbQueue.read { db in
            try Project.filter(Column("status") == ProjectStatus.active.rawValue)
                .filter(Column("deletedAt") == nil)
                .order(Column("updatedAt").desc)
                .fetchAll(db)
        }
    }

    public func project(id: UUID) throws -> Project? {
        try dbQueue.read { db in try Project.fetchOne(db, id: id) }
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

    /// All live threads, most-recent first.
    public func threads(limit: Int = 500) throws -> [OsmoThread] {
        try dbQueue.read { db in
            try OsmoThread.filter(Column("deletedAt") == nil)
                .order(Column("lastMessageAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// The most recent message in a thread (for inbox previews + snapshots).
    public func lastMessage(inThread threadID: UUID) throws -> OsmoMessage? {
        try dbQueue.read { db in
            try OsmoMessage.filter(Column("threadID") == threadID)
                .filter(Column("deletedAt") == nil)
                .order(Column("sentAt").desc)
                .fetchOne(db)
        }
    }

    // MARK: Identity graph

    public func contacts() throws -> [OsmoContact] {
        try dbQueue.read { db in
            try OsmoContact.filter(Column("deletedAt") == nil).fetchAll(db)
        }
    }

    public func people() throws -> [Person] {
        try dbQueue.read { db in
            try Person.filter(Column("deletedAt") == nil).fetchAll(db)
        }
    }

    public func person(id: UUID) throws -> Person? {
        try dbQueue.read { db in try Person.fetchOne(db, id: id) }
    }

    public func contacts(forPerson personID: UUID) throws -> [OsmoContact] {
        try dbQueue.read { db in
            try OsmoContact.filter(Column("personID") == personID)
                .filter(Column("deletedAt") == nil).fetchAll(db)
        }
    }

    /// The distinct sender contacts seen in a thread (the people it's with).
    public func contacts(inThread threadID: UUID) throws -> [OsmoContact] {
        try dbQueue.read { db in
            try OsmoContact.fetchAll(db, sql: """
                SELECT DISTINCT contact.* FROM contact
                JOIN message ON message.senderContactID = contact.id
                WHERE message.threadID = ? AND contact.deletedAt IS NULL
                """, arguments: [threadID])
        }
    }

    /// Resolve the identity graph over all contacts: deterministic phone/email
    /// clusters auto-merge into `Person` rows (reusing any existing person so
    /// reviewed/manual state survives), contacts get linked, and probabilistic
    /// name/avatar matches are returned as review suggestions (never auto-applied).
    @discardableResult
    public func rebuildIdentityGraph() throws -> [MergeSuggestion] {
        let all = try contacts()
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        let result = IdentityResolver.resolve(all)

        try dbQueue.write { db in
            for cluster in result.clusters {
                let members = cluster.compactMap { byID[$0] }
                guard !members.isEmpty else { continue }
                // Reuse an existing person if any member is already linked.
                let existingPID = members.compactMap(\.personID).first
                let person: Person
                if let pid = existingPID, let p = try Person.fetchOne(db, id: pid) {
                    person = p
                } else {
                    let name = members.map(\.displayName)
                        .compactMap { $0 }.first(where: { !$0.isEmpty })
                        ?? members[0].handle
                    let avatar = members.compactMap(\.avatarData).first
                    let pid = DeterministicID.v5(name: "person:\(cluster.min(by: { $0.uuidString < $1.uuidString })!.uuidString)")
                    person = Person(id: pid, displayName: name, avatarData: avatar)
                    var toSave = person
                    toSave.sync = SyncMeta(id: pid, updatedAt: Date(), deviceSeq: try nextSeq(db))
                    try toSave.save(db)
                }
                // Link every member contact to this person.
                for var c in members where c.personID != person.id {
                    c.personID = person.id
                    c.sync = SyncMeta(id: c.id, updatedAt: Date(), deviceSeq: try nextSeq(db))
                    try c.save(db)
                }
            }
        }
        return result.suggestions
    }

    /// Apply a confirmed merge: fold every contact of the listed people onto one
    /// surviving person, tombstone the others. Marks the survivor reviewed.
    @discardableResult
    public func mergePeople(_ ids: [UUID]) throws -> Person? {
        guard let survivorID = ids.first else { return nil }
        return try dbQueue.write { db in
            guard var survivor = try Person.fetchOne(db, id: survivorID) else { return nil }
            for otherID in ids.dropFirst() {
                let others = try OsmoContact.filter(Column("personID") == otherID).fetchAll(db)
                for var c in others {
                    c.personID = survivorID
                    c.sync = SyncMeta(id: c.id, updatedAt: Date(), deviceSeq: try nextSeq(db))
                    try c.save(db)
                }
                if var other = try Person.fetchOne(db, id: otherID) {
                    other.sync = SyncMeta(id: otherID, updatedAt: Date(),
                                          deviceSeq: try nextSeq(db), deletedAt: Date())
                    try other.save(db)
                }
            }
            survivor.reviewed = true
            survivor.sync = SyncMeta(id: survivorID, updatedAt: Date(), deviceSeq: try nextSeq(db))
            try survivor.save(db)
            return survivor
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
