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

    public func message(id: UUID) throws -> OsmoMessage? {
        try dbQueue.read { db in try OsmoMessage.fetchOne(db, id: id) }
    }

    // MARK: Reactions (tapbacks)

    /// Add/replace a tapback (idempotent — the deterministic id folds re-adds).
    public func upsertReaction(_ reaction: MessageReaction) throws {
        try dbQueue.write { db in try reaction.save(db) }
    }

    /// Remove a tapback by its deterministic id (a chat.db 3000-series row).
    public func removeReaction(id: UUID) throws {
        _ = try dbQueue.write { db in try MessageReaction.deleteOne(db, id: id) }
    }

    /// Every reaction on messages in a thread, keyed by target message id — one
    /// query for the whole transcript (no per-bubble store hit).
    public func reactions(inThread threadID: UUID) throws -> [UUID: [MessageReaction]] {
        try dbQueue.read { db in
            let rows = try MessageReaction.fetchAll(db, sql: """
                SELECT r.* FROM message_reaction r
                JOIN message m ON m.id = r.targetMessageID
                WHERE m.threadID = ? AND m.deletedAt IS NULL
                """, arguments: [threadID])
            return Dictionary(grouping: rows, by: { $0.targetMessageID })
        }
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

    /// The most recent `limit` messages in a thread, newest first — a bounded
    /// sample for the human/automated classifier (avoids loading full history per
    /// thread on every reload).
    public func recentMessages(inThread threadID: UUID, limit: Int = 30) throws -> [OsmoMessage] {
        try dbQueue.read { db in
            try OsmoMessage
                .filter(Column("threadID") == threadID)
                .filter(Column("deletedAt") == nil)
                .order(Column("sentAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Inbound messages since a date — the "N new" figure on Today.
    public func inboundMessageCount(since: Date) throws -> Int {
        try dbQueue.read { db in
            try OsmoMessage.filter(Column("isFromMe") == false)
                .filter(Column("deletedAt") == nil)
                .filter(Column("sentAt") >= since)
                .fetchCount(db)
        }
    }

    public func messageCount() throws -> Int {
        try dbQueue.read { db in
            try OsmoMessage.filter(Column("deletedAt") == nil).fetchCount(db)
        }
    }

    /// The user's own sent messages, newest first — the "You" voice-profile
    /// section's raw material. One indexed query; the app buckets by
    /// `.platform` (present on every row) rather than needing a per-thread scan.
    public func outboundMessages(limit: Int = 2000) throws -> [OsmoMessage] {
        try dbQueue.read { db in
            try OsmoMessage.filter(Column("isFromMe") == true)
                .filter(Column("deletedAt") == nil)
                .order(Column("sentAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    // MARK: Attachments

    /// Every attachment on messages in a thread, keyed by message id — one
    /// query for the whole transcript (same shape as `reactions(inThread:)`).
    public func attachments(inThread threadID: UUID) throws -> [UUID: [OsmoAttachment]] {
        try dbQueue.read { db in
            let rows = try OsmoAttachment.fetchAll(db, sql: """
                SELECT a.* FROM message_attachment a
                JOIN message m ON m.id = a.messageID
                WHERE m.threadID = ? AND m.deletedAt IS NULL AND a.deletedAt IS NULL
                """, arguments: [threadID])
            return Dictionary(grouping: rows, by: { $0.messageID })
        }
    }

    /// Record that an attachment's bytes have been fetched (or its inline
    /// thumbnail generated) — a device-local cache fill, NOT a content change,
    /// so it deliberately does NOT advance the sync clock (a file path on this
    /// Mac means nothing on another one).
    public func cacheAttachmentMedia(id: UUID, localPath: String? = nil, thumbnailData: Data? = nil) throws {
        try dbQueue.write { db in
            if let localPath {
                try db.execute(sql: "UPDATE message_attachment SET localPath = ? WHERE id = ?",
                               arguments: [localPath, id])
            }
            if let thumbnailData {
                try db.execute(sql: "UPDATE message_attachment SET thumbnailData = ? WHERE id = ?",
                               arguments: [thumbnailData, id])
            }
        }
    }

    /// Message count for a single platform — the "Connected · N messages" figure.
    public func messageCount(platform: Platform) throws -> Int {
        try dbQueue.read { db in
            try OsmoMessage.filter(Column("deletedAt") == nil)
                .filter(Column("platform") == platform.rawValue).fetchCount(db)
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

    /// Cheap live-contact count — a change signal for "should I rebuild the
    /// identity graph?" (the O(n) resolve is too expensive to run every reload).
    public func contactCount() throws -> Int {
        try dbQueue.read { db in
            try OsmoContact.filter(Column("deletedAt") == nil).fetchCount(db)
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

    /// One `searchPeople` result: the person, their resolved contacts, and the
    /// distinct platforms they're reachable on.
    public struct PersonHit: Equatable, Sendable, Identifiable {
        public var person: Person
        public var contacts: [OsmoContact]
        public var platforms: [Platform]
        public var id: UUID { person.id }
        public init(person: Person, contacts: [OsmoContact], platforms: [Platform]) {
            self.person = person; self.contacts = contacts; self.platforms = platforms
        }
    }

    /// Cross-platform person search — the pill's "who am I sending this to"
    /// picker. Matches the person's own display name, any of their contacts'
    /// display names, a raw handle substring, OR (when the query looks
    /// numeric) a phone number via `HandleNormalizer` so "415" finds someone
    /// by digits regardless of how the platform formatted the number. Contacts
    /// with no resolved personID are excluded — the pill's fuzzy thread-name
    /// match already covers unresolved names as a fallback.
    public func searchPeople(_ query: String, limit: Int = 8) throws -> [PersonHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        let queryDigits = q.filter(\.isNumber)

        return try dbQueue.read { db in
            let people = try Person.filter(Column("deletedAt") == nil).fetchAll(db)
            let contacts = try OsmoContact.filter(Column("deletedAt") == nil).fetchAll(db)
            let contactsByPerson = Dictionary(grouping: contacts.filter { $0.personID != nil }) { $0.personID! }

            var scored: [(person: Person, contacts: [OsmoContact], score: Int)] = []
            for person in people {
                let personContacts = contactsByPerson[person.id] ?? []
                var matched = false
                var score = 0
                let nameLower = person.displayName.lowercased()
                if nameLower.contains(q) {
                    matched = true
                    score = max(score, nameLower.hasPrefix(q) ? 2 : 1)
                }
                for c in personContacts {
                    if let name = c.displayName?.lowercased(), name.contains(q) {
                        matched = true; score = max(score, name.hasPrefix(q) ? 2 : 1)
                    }
                    if c.handle.lowercased().contains(q) {
                        matched = true; score = max(score, 1)
                    }
                    if !queryDigits.isEmpty {
                        let normalized = HandleNormalizer.normalize(c.handle)
                        if normalized.kind == .phone, normalized.value.contains(queryDigits) {
                            matched = true; score = max(score, 1)
                        }
                    }
                }
                if matched { scored.append((person, personContacts, score)) }
            }
            return scored
                .sorted { $0.score != $1.score ? $0.score > $1.score : $0.person.displayName < $1.person.displayName }
                .prefix(limit)
                .map { entry in
                    PersonHit(person: entry.person, contacts: entry.contacts,
                             platforms: Array(Set(entry.contacts.map(\.platform))).sorted { $0.rawValue < $1.rawValue })
                }
        }
    }

    /// Normalized handles of every non-me contact in any thread the user has
    /// actually sent a message in — cross-thread outbound reciprocity for the
    /// human classifier ("have I EVER written to this sender?"). One query per
    /// snapshot rebuild; keys use the same `HandleNormalizer` as the caller.
    public func outboundCounterpartyHandles() throws -> Set<String> {
        try dbQueue.read { db in
            let handles = try String.fetchAll(db, sql: """
                SELECT DISTINCT contact.handle FROM contact
                JOIN message ON message.senderContactID = contact.id
                WHERE contact.isMe = 0 AND contact.deletedAt IS NULL
                  AND message.deletedAt IS NULL
                  AND message.threadID IN (
                    SELECT DISTINCT threadID FROM message
                    WHERE isFromMe = 1 AND deletedAt IS NULL
                  )
                """)
            return Set(handles.map { HandleNormalizer.normalize($0).value })
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
        let result = IdentityResolver.resolve(all, rejectedPairKeys: try rejectedMergePairKeys(),
                                              excludedNames: try groupThreadTitles())

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

    // MARK: Merge decisions (rejected pairs)

    /// Record that the user reviewed two suggested clusters and said they are NOT
    /// the same person. Keyed by the identity graph's stable pair key so the
    /// suggestion never comes back. Idempotent.
    public func rejectMergePair(contactIDsA: [UUID], contactIDsB: [UUID]) throws {
        let key = IdentityResolver.pairKey(contactIDsA, contactIDsB)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO merge_decision (pairKey, decision, at) VALUES (?, 'rejected', ?)
                ON CONFLICT(pairKey) DO UPDATE SET decision = 'rejected', at = excluded.at
                """, arguments: [key, Date()])
        }
    }

    /// Every pair the user has explicitly rejected — filtered out of suggestions.
    public func rejectedMergePairKeys() throws -> Set<String> {
        try dbQueue.read { db in
            let keys = try String.fetchAll(db, sql:
                "SELECT pairKey FROM merge_decision WHERE decision = 'rejected'")
            return Set(keys)
        }
    }

    /// Every group thread's title, lowercased — fed to the identity resolver
    /// as `excludedNames` so a contact whose displayName ended up being a
    /// group's title (a null-title group falling back to it, or a sender-
    /// attribution bug upstream) never spams merge suggestions against every
    /// other contact that inherited the same generic label.
    private func groupThreadTitles() throws -> Set<String> {
        try dbQueue.read { db in
            let titles = try String.fetchAll(db, sql: """
                SELECT DISTINCT title FROM thread
                WHERE isGroup = 1 AND title IS NOT NULL AND title <> '' AND deletedAt IS NULL
                """)
            return Set(titles.map { $0.lowercased() })
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
