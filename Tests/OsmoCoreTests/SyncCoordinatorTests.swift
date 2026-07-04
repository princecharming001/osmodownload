import Testing
import Foundation
import GRDB
@testable import OsmoCore

@Suite("SyncCoordinator (L2)")
struct SyncCoordinatorTests {

    private func appleNanos(_ unix: TimeInterval) -> Int64 {
        Int64((unix - AppleTime.cocoaEpochOffset) * 1_000_000_000)
    }

    private func makeChatDB() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sc-\(UUID().uuidString).db")
        let db = try DatabaseQueue(path: url.path)
        try db.write { db in
            try db.execute(sql: "CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT)")
            try db.execute(sql: "CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, chat_identifier TEXT, display_name TEXT, style INTEGER)")
            try db.execute(sql: "CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT, handle_id INTEGER, is_from_me INTEGER, date INTEGER, date_read INTEGER)")
            try db.execute(sql: "CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER)")
            try db.execute(sql: "INSERT INTO handle (ROWID, id) VALUES (1, '+15551234567')")
            try db.execute(sql: "INSERT INTO chat (ROWID, guid, chat_identifier, display_name, style) VALUES (1, 'iMessage;-;+15551234567', '+15551234567', NULL, 45)")
            try db.execute(sql: "INSERT INTO message (ROWID, guid, text, handle_id, is_from_me, date, date_read) VALUES (1,'G1','are you around this weekend',1,0,?,0)", arguments: [appleNanos(1_800_000_000)])
            try db.execute(sql: "INSERT INTO chat_message_join (chat_id, message_id) VALUES (1,1)")
        }
        return url
    }

    @Test("syncAll imports iMessage from a readable chat.db and rebuilds identity")
    func syncsIMessage() async throws {
        let chatDB = try makeChatDB()
        defer { try? FileManager.default.removeItem(at: chatDB) }
        let store = try OsmoStore.inMemory()
        let coord = SyncCoordinator(store: store, iMessageDBPath: chatDB)

        let summary = await coord.syncAll()
        #expect(summary.contains("iMessage 1 new"))
        #expect(try store.messageCount() == 1)
        #expect(try store.search("weekend").count == 1)
        // Identity graph ran (the phone handle resolved to a person).
        #expect(try store.people().count == 1)
    }

    @Test("A missing chat.db degrades to a Full Disk Access note, not a crash")
    func missingDB() async throws {
        let store = try OsmoStore.inMemory()
        let coord = SyncCoordinator(store: store,
                                    iMessageDBPath: URL(fileURLWithPath: "/nonexistent/chat.db"))
        let summary = await coord.syncAll()
        #expect(summary.contains("Full Disk Access"))
        #expect(try store.messageCount() == 0)
    }

    @Test("Gmail sync fetches → normalizes → ingests via injected transport")
    func gmailSync() async throws {
        let store = try OsmoStore.inMemory()
        let listJSON = #"{"messages":[{"id":"g1"}]}"#
        let msgJSON = #"""
        {"id":"g1","threadId":"t1","internalDate":"1800000000000","snippet":"the proposal looks great",
         "payload":{"headers":[{"name":"From","value":"Client <client@acme.com>"},{"name":"To","value":"me@self.com"},{"name":"Subject","value":"Proposal"}]}}
        """#
        let coord = SyncCoordinator(
            store: store,
            iMessageDBPath: URL(fileURLWithPath: "/nonexistent"),
            credentials: .init(gmailAccessToken: "tok", gmailSelfEmail: "me@self.com"),
            transport: { req in
                let body = req.url!.path.contains("/messages/g1") ? msgJSON : listJSON
                return (Data(body.utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
        let n = try await coord.syncGmail()
        #expect(n == 1)
        #expect(try store.search("proposal").count == 1)
        #expect(try store.contacts().contains { $0.handle == "client@acme.com" })
    }
}
