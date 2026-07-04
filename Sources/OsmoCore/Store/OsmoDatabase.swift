import Foundation
import GRDB

/// The database open-seam and schema. **All disk encryption lives here** and
/// nowhere else. `open` uses SQLCipher (GRDB is vendored with the codec enabled —
/// see vendor/GRDB): pass a passphrase and the whole database file is AES-encrypted
/// at rest — no SQLite header, no message text recoverable from the raw bytes
/// (proved by EncryptionTests). The app supplies a Keychain-held key
/// ([KeychainDBKey]); tests and dev pass nil for plain SQLite. macOS
/// `FileProtectionType` only reaches volume-level, so this app-layer whole-DB
/// encryption is what backs the "encrypted on your Mac" guarantee.
public enum OsmoDatabase {

    /// Open (creating if needed) the Osmo store at `url`, running migrations.
    /// - Parameter passphrase: the SQLCipher key. A non-empty value encrypts the
    ///   whole database at rest; nil/empty opens plain SQLite (tests, dev). The key
    ///   must be applied before any other statement, which `prepareDatabase` guarantees.
    public static func open(at url: URL, passphrase: String? = nil) throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        // SQLCipher: encrypt the whole database at rest. GRDB is vendored with the
        // codec enabled (vendor/GRDB), so `usePassphrase` is compiled in. Applied
        // before any other statement runs, per SQLCipher's requirement. A nil/empty
        // passphrase leaves the DB as plain SQLite (dev/tests); production passes a
        // Keychain-held key so the file is opaque ciphertext on disk.
        if let passphrase, !passphrase.isEmpty {
            config.prepareDatabase { db in try db.usePassphrase(passphrase) }
        }
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        try migrator.migrate(queue)
        return queue
    }

    /// An in-memory store for tests.
    public static func openInMemory() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        try migrator.migrate(queue)
        return queue
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1-schema") { db in
            // device: this Mac's identity + the monotonic sync sequence source.
            try db.create(table: "device") { t in
                t.primaryKey("id", .text)
                t.column("seq", .integer).notNull().defaults(to: 0)
            }

            // Shared sync columns on every entity (the P0 sync-ready decision).
            func syncColumns(_ t: TableDefinition) {
                t.primaryKey("id", .text)
                t.column("updatedAt", .datetime).notNull()
                t.column("deviceSeq", .integer).notNull()
                t.column("deletedAt", .datetime)   // tombstone; null = live
            }

            try db.create(table: "contact") { t in
                syncColumns(t)
                t.column("platform", .text).notNull()
                t.column("handle", .text).notNull()
                t.column("displayName", .text)
                t.column("avatarData", .blob)
                t.column("personID", .text)        // identity-graph link (P3)
                t.column("isMe", .boolean).notNull().defaults(to: false)
                t.uniqueKey(["platform", "handle"])
            }
            try db.create(indexOn: "contact", columns: ["personID"])

            try db.create(table: "thread") { t in
                syncColumns(t)
                t.column("platform", .text).notNull()
                t.column("platformThreadID", .text).notNull()
                t.column("title", .text)
                t.column("isGroup", .boolean).notNull().defaults(to: false)
                t.column("lastMessageAt", .datetime)
                t.uniqueKey(["platform", "platformThreadID"])
            }

            try db.create(table: "message") { t in
                syncColumns(t)
                t.column("platform", .text).notNull()
                t.column("platformMessageID", .text).notNull()
                t.column("threadID", .text).notNull()
                    .references("thread", onDelete: .cascade)
                t.column("senderContactID", .text)
                    .references("contact", onDelete: .setNull)
                t.column("isFromMe", .boolean).notNull()
                t.column("text", .text).notNull()
                t.column("sentAt", .datetime).notNull()
                t.column("readAt", .datetime)
                t.uniqueKey(["platform", "platformMessageID"])
            }
            try db.create(indexOn: "message", columns: ["threadID", "sentAt"])
        }

        // FTS5 external-content index over message.text — the unified cross-platform
        // search that's a headline feature. `synchronize(withTable:)` installs the
        // insert/update/delete triggers that keep the index in lockstep.
        migrator.registerMigration("v2-fts") { db in
            try db.create(virtualTable: "message_ft", using: FTS5()) { t in
                t.synchronize(withTable: "message")
                t.tokenizer = .unicode61(diacritics: .remove)
                t.column("text")
            }
        }

        // User-authored, synced entities: durable per-person memory + goal-directed
        // projects (the wedge). Same sync columns; JSON columns for nested arrays.
        migrator.registerMigration("v3-memory-projects") { db in
            try db.create(table: "relationship_memory") { t in
                t.primaryKey("id", .text)          // == personID
                t.column("updatedAt", .datetime).notNull()
                t.column("deviceSeq", .integer).notNull()
                t.column("deletedAt", .datetime)
                t.column("note", .text).notNull().defaults(to: "")
                t.column("facts", .jsonText).notNull().defaults(to: "[]")
                t.column("summary", .text)
            }

            try db.create(table: "project") { t in
                t.primaryKey("id", .text)
                t.column("updatedAt", .datetime).notNull()
                t.column("deviceSeq", .integer).notNull()
                t.column("deletedAt", .datetime)
                t.column("personID", .text).notNull()
                t.column("title", .text).notNull()
                t.column("goalText", .text).notNull()
                t.column("toneHint", .text)
                t.column("boundaries", .jsonText).notNull().defaults(to: "[]")
                t.column("selfContext", .text)
                t.column("milestones", .jsonText).notNull().defaults(to: "[]")
                t.column("status", .text).notNull().defaults(to: "active")
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(indexOn: "project", columns: ["personID"])
        }

        // Identity graph: the merged cross-platform person. `contact.personID`
        // points here (already a column since v1).
        migrator.registerMigration("v4-person") { db in
            try db.create(table: "person") { t in
                t.primaryKey("id", .text)
                t.column("updatedAt", .datetime).notNull()
                t.column("deviceSeq", .integer).notNull()
                t.column("deletedAt", .datetime)
                t.column("displayName", .text).notNull()
                t.column("avatarData", .blob)
                t.column("reviewed", .boolean).notNull().defaults(to: false)
            }
        }

        return migrator
    }
}
