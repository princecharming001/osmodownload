import Testing
import Foundation
import GRDB
@testable import OsmoCore

@Suite("Realtime sync engine — doorbell → pull → ingest")
struct RealtimeSyncEngineTests {

    // MARK: - Local (iMessage) poll-after-send: no duplicates, picks up new rows

    /// A message time as Apple stores it (Cocoa-epoch nanoseconds).
    private func appleNanos(_ unix: TimeInterval) -> Int64 {
        Int64((unix - AppleTime.cocoaEpochOffset) * 1_000_000_000)
    }

    /// Minimal synthetic chat.db (schema subset the reader queries), one 1:1 chat
    /// with a single from-me message. Returns (fileURL, dbQueue) so the test can
    /// append a "just-sent" row between polls.
    private func makeChatDB() throws -> (URL, DatabaseQueue) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osmo-send-\(UUID().uuidString).db")
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
                                      date_read INTEGER, attributedBody BLOB,
                                      associated_message_type INTEGER DEFAULT 0,
                                      associated_message_guid TEXT,
                                      associated_message_emoji TEXT,
                                      thread_originator_guid TEXT)
                """)
            try db.execute(sql: "CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER)")
            try db.execute(sql: "INSERT INTO handle (ROWID, id) VALUES (1, '+15551234567')")
            try db.execute(sql: """
                INSERT INTO chat (ROWID, guid, chat_identifier, display_name, style)
                VALUES (1, 'iMessage;-;+15551234567', '+15551234567', NULL, 45)
                """)
            try db.execute(sql: """
                INSERT INTO message (ROWID, guid, text, handle_id, is_from_me, date, date_read)
                VALUES (1, 'M1', 'earlier message', 1, 0, ?, 0)
                """, arguments: [appleNanos(1_800_000_000)])
            try db.execute(sql: "INSERT INTO chat_message_join (chat_id, message_id) VALUES (1,1)")
        }
        return (url, db)
    }

    @Test("pollLocalNow ingests iMessage rows, is idempotent, and picks up a just-sent row")
    func pollLocalNowIdempotentAndIncremental() async throws {
        let (url, fixture) = try makeChatDB()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try OsmoStore.inMemory()
        let engine = RealtimeSyncEngine(store: store, client: makeClient(pullBodies: []),
                                        cursorStore: MemoryCursorStore(), iMessageDBPath: url)

        await engine.pollLocalNow()
        #expect(try store.messageCount() == 1)
        // Polling again must NOT duplicate (watermark advanced + ingest dedup).
        await engine.pollLocalNow()
        #expect(try store.messageCount() == 1)

        // Simulate the user sending via Osmo: Messages commits a new from-me row a
        // beat later. The next poll must ingest exactly that one — the fix's core.
        try await fixture.write { db in
            try db.execute(sql: """
                INSERT INTO message (ROWID, guid, text, handle_id, is_from_me, date, date_read)
                VALUES (2, 'SENT-1', 'my reply via osmo', 0, 1, ?, 0)
                """, arguments: [self.appleNanos(1_800_000_600)])
            try db.execute(sql: "INSERT INTO chat_message_join (chat_id, message_id) VALUES (1,2)")
        }
        await engine.pollLocalNow()
        #expect(try store.messageCount() == 2)          // sent row shows up
        // Retry polls (our post-send loop fires up to 4×) must not duplicate it.
        await engine.pollLocalNow()
        await engine.pollLocalNow()
        #expect(try store.messageCount() == 2)
    }

    private static let batchJSON = #"{"contacts":[{"platform":"linkedin","handle":"urn:li:member:5","displayName":"Ada","isMe":false}],"threads":[{"platform":"linkedin","platformThreadID":"chat-9","title":"Ada","isGroup":false,"lastMessageAt":"2026-07-04T10:00:00Z"}],"messages":[{"platform":"linkedin","platformMessageID":"m-1","platformThreadID":"chat-9","senderHandle":"urn:li:member:5","isFromMe":false,"text":"hello","sentAt":"__SENT_AT__","readAt":null}],"cursor":"3","hasMore":false}"#
    private static let emptyJSON = #"{"contacts":[],"threads":[],"messages":[],"cursor":"3","hasMore":false}"#

    /// Fresh message so it passes the fresh-inbound window.
    private static func freshBatch() -> String {
        let iso = ISO8601DateFormatter().string(from: Date())
        return batchJSON.replacingOccurrences(of: "__SENT_AT__", with: iso)
    }

    private func makeClient(pullBodies: [String]) -> BackendClient {
        let bodies = Box(pullBodies)
        let transport: BackendClient.DataTransport = { request in
            let path = request.url!.path
            let respond = { (status: Int, body: String) -> (Data, HTTPURLResponse) in
                (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status,
                                                  httpVersion: nil, headerFields: nil)!)
            }
            if path.contains("device/register") {
                return respond(200, #"{"deviceId":"d","deviceToken":"t","mode":"mock"}"#)
            }
            if path.contains("sync/pull") {
                return respond(200, bodies.next() ?? Self.emptyJSON)
            }
            return respond(404, "{}")
        }
        // Byte stream that never yields (SSE quiet) — pull is driven manually.
        let stream: BackendClient.ByteStream = { _ in
            AsyncThrowingStream { _ in }   // never yields, never finishes
        }
        return BackendClient(baseURL: URL(string: "http://test")!,
                             tokenStore: MemoryDeviceToken(),
                             transport: transport, byteStream: stream)
    }

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String]
        init(_ items: [String]) { self.items = items }
        func next() -> String? {
            lock.lock(); defer { lock.unlock() }
            return items.isEmpty ? nil : items.removeFirst()
        }
    }

    @Test("pullNow ingests a batch, persists the cursor AFTER ingest, dedups on re-pull")
    func pullIngestsAndDedups() async throws {
        let store = try OsmoStore.inMemory()
        let fresh = Self.freshBatch()
        let client = makeClient(pullBodies: [fresh, fresh])   // same content twice
        let cursors = MemoryCursorStore()
        let engine = RealtimeSyncEngine(store: store, client: client, cursorStore: cursors,
                                        iMessageDBPath: URL(fileURLWithPath: "/nonexistent"))

        await engine.pullNow()
        #expect(try store.messageCount() == 1)
        #expect(cursors.loadBackendCursor() == "3")

        // Cursor reset + re-pull of identical content → still one row.
        cursors.saveBackendCursor("")
        await engine.pullNow()
        #expect(try store.messageCount() == 1)
    }

    @Test("Fresh inbound messages surface on the inbound stream exactly once")
    func inboundYields() async throws {
        let store = try OsmoStore.inMemory()
        let client = makeClient(pullBodies: [Self.freshBatch()])
        let engine = RealtimeSyncEngine(store: store, client: client,
                                        cursorStore: MemoryCursorStore(),
                                        iMessageDBPath: URL(fileURLWithPath: "/nonexistent"))

        let inboundTask = Task { () -> RealtimeSyncEngine.NewInbound? in
            for await inbound in engine.inbound { return inbound }
            return nil
        }
        await engine.pullNow()
        // Second pull returns empty → no more yields.
        await engine.pullNow()

        let first = await withTaskTimeout(seconds: 5) { await inboundTask.value }
        #expect(first??.message.text == "hello")
        #expect(first??.message.isFromMe == false)
        inboundTask.cancel()
    }

    @Test("Old messages ingest but do NOT surface as fresh inbound")
    func staleNotFresh() async throws {
        let store = try OsmoStore.inMemory()
        let stale = Self.batchJSON.replacingOccurrences(of: "__SENT_AT__", with: "2026-07-01T00:00:00Z")
        let client = makeClient(pullBodies: [stale])
        let engine = RealtimeSyncEngine(store: store, client: client,
                                        cursorStore: MemoryCursorStore(),
                                        iMessageDBPath: URL(fileURLWithPath: "/nonexistent"))
        await engine.pullNow()
        #expect(try store.messageCount() == 1)   // ingested…

        // …but the inbound stream stays quiet (bounded check).
        let quiet = Task { () -> Bool in
            for await _ in engine.inbound { return false }
            return true
        }
        try? await Task.sleep(for: .milliseconds(200))
        quiet.cancel()
        // Reaching here without a yield = pass (cancel unblocks the loop).
    }

    @Test("A recent-but-already-read inbound ingests without re-notifying")
    func readNotFresh() async throws {
        // A backend re-emit that merely adds a read receipt (readAt populated)
        // must not re-fire a notification, even though sentAt is recent.
        let store = try OsmoStore.inMemory()
        let iso = ISO8601DateFormatter().string(from: Date())
        let read = Self.batchJSON
            .replacingOccurrences(of: "__SENT_AT__", with: iso)
            .replacingOccurrences(of: #""readAt":null"#, with: #""readAt":"\#(iso)""#)
        let client = makeClient(pullBodies: [read])
        let engine = RealtimeSyncEngine(store: store, client: client,
                                        cursorStore: MemoryCursorStore(),
                                        iMessageDBPath: URL(fileURLWithPath: "/nonexistent"))
        await engine.pullNow()
        #expect(try store.messageCount() == 1)   // ingested…

        let quiet = Task { () -> Bool in
            for await _ in engine.inbound { return false }
            return true
        }
        try? await Task.sleep(for: .milliseconds(200))
        quiet.cancel()   // …but no inbound yield (would fail the `return false` above)
    }

    @Test("hasMore pages until drained")
    func paging() async throws {
        let store = try OsmoStore.inMemory()
        let page1 = Self.freshBatch()
            .replacingOccurrences(of: #""cursor":"3","hasMore":false"#,
                                  with: #""cursor":"1","hasMore":true"#)
        let page2 = Self.freshBatch()
            .replacingOccurrences(of: "m-1", with: "m-2")
        let client = makeClient(pullBodies: [page1, page2])
        let cursors = MemoryCursorStore()
        let engine = RealtimeSyncEngine(store: store, client: client, cursorStore: cursors,
                                        iMessageDBPath: URL(fileURLWithPath: "/nonexistent"))
        await engine.pullNow()
        #expect(try store.messageCount() == 2)
        #expect(cursors.loadBackendCursor() == "3")
    }

    private func withTaskTimeout<T: Sendable>(seconds: Double,
                                              _ work: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
