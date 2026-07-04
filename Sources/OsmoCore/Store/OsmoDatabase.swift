import Foundation
import GRDB

/// The database open-seam and schema. **All disk encryption plugs in here** and
/// nowhere else: today `open` uses vanilla GRDB (system SQLite); the SQLCipher
/// swap replaces the queue construction with a SQLCipher-backed configuration
/// (passphrase from Keychain) — every caller above this line is unchanged.
/// macOS `FileProtectionType` only reaches volume-level, so app-layer whole-DB
/// encryption is required for the "encrypted on your Mac" guarantee; that swap
/// is the next storage slice and is deliberately isolated to this file.
public enum OsmoDatabase {

    /// Open (creating if needed) the Osmo store at `url`, running migrations.
    /// - Parameter passphrase: the SQLCipher key. Ignored by the vanilla-GRDB
    ///   build; wired when SQLCipher lands (the parameter exists now so call
    ///   sites don't change at the swap).
    public static func open(at url: URL, passphrase: String? = nil) throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        // SQLCipher seam: when the SQLCipher GRDB flavor is in place,
        //   config.prepareDatabase { db in try db.usePassphrase(passphrase!) }
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

        return migrator
    }
}
