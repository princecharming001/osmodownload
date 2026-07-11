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

        // Consumer-shell state: per-thread compose drafts, snoozes, and the
        // offline send queue. Device-local UX state, not synced entities — so
        // plain tables without the SyncMeta columns.
        migrator.registerMigration("v5-drafts-snooze-sendqueue") { db in
            try db.create(table: "thread_draft") { t in
                t.primaryKey("threadID", .text)
                    .references("thread", onDelete: .cascade)
                t.column("text", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "thread_snooze") { t in
                t.primaryKey("threadID", .text)
                    .references("thread", onDelete: .cascade)
                t.column("until", .datetime).notNull()
            }
            try db.create(table: "send_queue") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("platform", .text).notNull()
                t.column("platformThreadID", .text).notNull()
                t.column("text", .text).notNull()
                t.column("queuedAt", .datetime).notNull()
                t.column("attempts", .integer).notNull().defaults(to: 0)
            }
        }

        // A record of the user's explicit "not the same person" decisions, keyed
        // by the identity graph's stable pair key, so a rejected merge suggestion
        // never reappears. Device-local UX state (not a synced entity).
        migrator.registerMigration("v6-merge-decisions") { db in
            try db.create(table: "merge_decision") { t in
                t.primaryKey("pairKey", .text)
                t.column("decision", .text).notNull()   // "rejected"
                t.column("at", .datetime).notNull()
            }
        }

        // iMessage fidelity: tapback reactions (their own table so a reaction is
        // never a message bubble) + a reply-parent pointer on messages. Additive
        // (ALTER + CREATE only) — migration-safe, no data rewrite. No FK on
        // targetMessageID on purpose: a reaction can point at a message outside
        // the pulled window (or a media message we skip), and a hard FK would fail
        // the insert; display JOINs simply drop reactions with no visible target.
        migrator.registerMigration("v7-reactions-replies") { db in
            try db.alter(table: "message") { t in
                t.add(column: "inReplyToMessageID", .text)
            }
            try db.create(table: "message_reaction") { t in
                t.primaryKey("id", .text)
                t.column("targetMessageID", .text).notNull()
                t.column("reactorContactID", .text)
                t.column("reactionType", .text).notNull()
                t.column("emoji", .text).notNull()
                t.column("isFromMe", .boolean).notNull().defaults(to: false)
                t.column("reactedAt", .datetime).notNull()
            }
            try db.create(index: "idx_reaction_target",
                          on: "message_reaction", columns: ["targetMessageID"])
        }

        // Follow-up reminders: "nudge me if no reply" per thread. Device-local
        // UX state (like drafts/snoozes) — additive, migration-safe.
        migrator.registerMigration("v8-followups") { db in
            try db.create(table: "thread_followup") { t in
                t.primaryKey("threadID", .text)
                    .references("thread", onDelete: .cascade)
                t.column("due", .datetime).notNull()
                t.column("setAt", .datetime).notNull()
            }
        }

        // Public-profile enrichment (LinkedIn + web) per person. Device-local
        // cache — re-fetchable from the backend, so no sync columns; cascades
        // away when its person is deleted or merged.
        migrator.registerMigration("v9-person-enrichment") { db in
            try db.create(table: "person_enrichment") { t in
                t.primaryKey("personID", .text)
                    .references("person", onDelete: .cascade)
                t.column("headline", .text)
                t.column("company", .text)
                t.column("title", .text)
                t.column("location", .text)
                t.column("summary", .text)
                t.column("linkedinURL", .text)
                t.column("positions", .text).notNull().defaults(to: "[]")
                t.column("education", .text).notNull().defaults(to: "[]")
                t.column("webFacts", .text).notNull().defaults(to: "[]")
                t.column("source", .text).notNull()
                t.column("fetchedAt", .datetime).notNull()
            }
        }

        // Server-side automated-sender signal (Gmail List-Unsubscribe/Precedence/
        // sender-shape) + the provider's OWN thread id (distinct from Unipile's
        // internal chat id — what a working deep link into the real conversation
        // actually needs). Both land on `thread` together since they're trivial
        // nullable/defaulted columns on the same table.
        migrator.registerMigration("v10-thread-hints") { db in
            try db.alter(table: "thread") { t in
                t.add(column: "automatedHint", .boolean).notNull().defaults(to: false)
                t.add(column: "providerThreadID", .text)
            }
        }

        // Marks a draft as Osmo's own (autodraft-on-arrival) vs. user-typed —
        // the never-overwrite-user-text rule reads this flag.
        migrator.registerMigration("v11-autodraft-flag") { db in
            try db.alter(table: "thread_draft") { t in
                t.add(column: "isAuto", .boolean).notNull().defaults(to: false)
            }
        }

        // Media attachments (image/video/audio/file/link) on a message. Cascades
        // away with its message; `localPath`/`thumbnailData` are device-local
        // cache fields the reader never writes (see `preservingEnrichment`).
        migrator.registerMigration("v12-message-attachment") { db in
            try db.create(table: "message_attachment") { t in
                t.primaryKey("id", .text)
                t.column("updatedAt", .datetime).notNull()
                t.column("deviceSeq", .integer).notNull()
                t.column("deletedAt", .datetime)
                t.column("messageID", .text).notNull().references("message", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("mimeType", .text)
                t.column("filename", .text)
                t.column("sizeBytes", .integer)
                t.column("width", .integer)
                t.column("height", .integer)
                t.column("remoteRef", .text)
                t.column("linkURL", .text)
                t.column("title", .text)
                t.column("localPath", .text)
                t.column("thumbnailData", .blob)
            }
            try db.create(index: "idx_attachment_message",
                          on: "message_attachment", columns: ["messageID"])
        }

        // Indexes for the outbound-reciprocity scan (`outboundCounterpartyHandles`)
        // — it runs on every snapshot rebuild (~0.5s cadence during an import) and
        // both of its legs were full message-table scans: the sender join needs
        // message(senderContactID), and the "did I ever write in this thread"
        // EXISTS probe needs message(threadID, isFromMe). The v1 index on
        // message(threadID, sentAt) doesn't cover the isFromMe test.
        migrator.registerMigration("v13-outbound-reciprocity-indexes") { db in
            try db.create(index: "idx_message_sender",
                          on: "message", columns: ["senderContactID"])
            try db.create(index: "idx_message_thread_fromme",
                          on: "message", columns: ["threadID", "isFromMe"])
        }

        // A stable idempotency key per queued send: a lost-response retry
        // (drainSendQueue re-sending after a timeout where the server actually
        // delivered) used to double-send to the real recipient — the server's
        // sendOnce/recallSend machinery already existed but nothing on the
        // client ever generated or persisted a key. The key is minted once
        // when a send is first attempted and reused on every retry.
        migrator.registerMigration("v14-send-idempotency") { db in
            try db.alter(table: "send_queue") { t in
                t.add(column: "idempotencyKey", .text)
            }
        }

        return migrator
    }
}
