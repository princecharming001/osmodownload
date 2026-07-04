import Testing
import Foundation
import GRDB
@testable import OsmoCore

@Suite("iMessage chat.db reader + normalizer (P0.4)")
struct IMessageImportTests {

    /// A message time as Apple stores it: Cocoa-epoch nanoseconds.
    private func appleNanos(unix: TimeInterval) -> Int64 {
        Int64((unix - AppleTime.cocoaEpochOffset) * 1_000_000_000)
    }

    /// Build a synthetic chat.db with Apple's schema subset + fixture rows, at a
    /// temp path. Returns the file URL (caller imports it read-only).
    private func makeFixtureDB() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osmo-fixture-\(UUID().uuidString).db")
        let db = try DatabaseQueue(path: url.path)
        try db.write { db in
            try db.execute(sql: "CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT)")
            try db.execute(sql: """
                CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, chat_identifier TEXT,
                                   display_name TEXT, style INTEGER)
                """)
            try db.execute(sql: """
                CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT,
                                      handle_id INTEGER, is_from_me INTEGER, date INTEGER,
                                      date_read INTEGER, attributedBody BLOB)
                """)
            try db.execute(sql: "CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER)")

            try db.execute(sql: "INSERT INTO handle (ROWID, id) VALUES (1, '+15551234567')")
            // 1:1 chat (Sequoia-style prefix) + a group chat (Tahoe-style prefix).
            try db.execute(sql: """
                INSERT INTO chat (ROWID, guid, chat_identifier, display_name, style)
                VALUES (1, 'iMessage;-;+15551234567', '+15551234567', NULL, 45),
                       (2, 'any;+;chat9', 'chat9', 'Trip Planning', 43)
                """)

            let t1 = appleNanos(unix: 1_800_000_000)   // incoming, in 1:1
            let t1read = appleNanos(unix: 1_800_000_300)
            let t2 = appleNanos(unix: 1_800_000_600)   // from me, in 1:1
            let t3 = appleNanos(unix: 1_800_001_000)   // group, from handle 1
            try db.execute(sql: """
                INSERT INTO message (ROWID, guid, text, handle_id, is_from_me, date, date_read)
                VALUES
                  (1, 'G1', 'are you free friday', 1, 0, ?, ?),
                  (2, 'G2', 'yes lets do it', 0, 1, ?, 0),
                  (3, 'G3', 'who is driving to friday dinner', 1, 0, ?, 0)
                """, arguments: [t1, t1read, t2, t3])
            // A rich message with no text column (attributedBody only) — must be skipped.
            try db.execute(sql: """
                INSERT INTO message (ROWID, guid, text, handle_id, is_from_me, date, date_read)
                VALUES (4, 'G4', NULL, 1, 0, ?, 0)
                """, arguments: [appleNanos(unix: 1_800_002_000)])

            try db.execute(sql: """
                INSERT INTO chat_message_join (chat_id, message_id)
                VALUES (1,1),(1,2),(2,3)
                """)
        }
        return url
    }

    @Test("Reader + normalizer ingest real-shaped chat.db rows into the store")
    func importIntoStore() throws {
        let url = try makeFixtureDB()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try OsmoStore.inMemory()

        let stats = try IMessageImporter().importAll(from: url, into: store)
        #expect(stats.threads == 2)          // 1:1 + group
        #expect(stats.messages == 3)         // the attributedBody-only row is skipped
        #expect(stats.contacts == 1)         // one non-me handle
        #expect(stats.newlyIngested == 3)
        #expect(try store.messageCount() == 3)
        #expect(try store.threadCount() == 2)
    }

    @Test("Timestamps, read receipts, and from-me attribution decode correctly")
    func fieldFidelity() throws {
        let url = try makeFixtureDB()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try OsmoStore.inMemory()
        try IMessageImporter().importAll(from: url, into: store)

        let oneToOne = OsmoThread.makeID(platform: .imessage, platformThreadID: "+15551234567")
        let msgs = try store.messages(inThread: oneToOne)
        #expect(msgs.count == 2)
        let incoming = msgs[0]
        #expect(incoming.text == "are you free friday")
        #expect(!incoming.isFromMe)
        #expect(incoming.senderContactID != nil)
        #expect(abs(incoming.sentAt.timeIntervalSince1970 - 1_800_000_000) < 1)   // Cocoa-ns decoded
        #expect(incoming.readAt != nil)                                            // read receipt = fact
        #expect(abs(incoming.readAt!.timeIntervalSince1970 - 1_800_000_300) < 1)
        let outgoing = msgs[1]
        #expect(outgoing.isFromMe)
        #expect(outgoing.senderContactID == nil)                                   // from me → no contact
    }

    @Test("Group thread keeps its title + group flag; keyed on chat_identifier not the Tahoe GUID")
    func groupThread() throws {
        let url = try makeFixtureDB()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try OsmoStore.inMemory()
        try IMessageImporter().importAll(from: url, into: store)

        // Keyed on 'chat9' (chat_identifier), NOT 'any;+;chat9' (the prefixed GUID).
        let group = try store.thread(id: OsmoThread.makeID(platform: .imessage,
                                                           platformThreadID: "chat9"))
        #expect(group != nil)
        #expect(group?.isGroup == true)
        #expect(group?.title == "Trip Planning")
    }

    @Test("Re-import is idempotent (dedup) but picks up a newly-arrived read receipt")
    func idempotentReimport() throws {
        let url = try makeFixtureDB()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try OsmoStore.inMemory()

        let first = try IMessageImporter().importAll(from: url, into: store)
        #expect(first.newlyIngested == 3)
        let second = try IMessageImporter().importAll(from: url, into: store)
        #expect(second.newlyIngested == 0)   // nothing changed → no writes
        #expect(try store.messageCount() == 3)
    }

    @Test("Imported messages are searchable via unified FTS")
    func searchable() throws {
        let url = try makeFixtureDB()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try OsmoStore.inMemory()
        try IMessageImporter().importAll(from: url, into: store)
        #expect(try store.search("friday").count == 2)     // 1:1 + group both mention friday
        #expect(try store.search("driving").count == 1)
    }
}
