import Testing
import Foundation
@testable import OsmoCore

/// Malformed-wire and stream-identity edges for the backend pull path: rows the
/// backend should never send but one day will — orphan messages, empty handles,
/// duplicate ids, future timestamps, flapping epochs — must degrade to "row
/// skipped" or "reset once", never a crash, a visible orphan, or a reset loop.
@Suite("Sync engine edges — malformed wire data + epoch flapping")
struct SyncEngineEdgeTests {

    // MARK: - Transport plumbing (same seam as RealtimeSyncEngineTests)

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String]
        private(set) var pullCount = 0
        init(_ items: [String]) { self.items = items }
        func next() -> String? {
            lock.lock(); defer { lock.unlock() }
            pullCount += 1
            return items.isEmpty ? nil : items.removeFirst()
        }
        var pulls: Int { lock.lock(); defer { lock.unlock() }; return pullCount }
    }

    static let emptyJSON = #"{"contacts":[],"threads":[],"messages":[],"cursor":"9","hasMore":false}"#

    private func makeClient(_ bodies: Box) -> BackendClient {
        let transport: BackendClient.DataTransport = { request in
            let respond = { (status: Int, body: String) -> (Data, HTTPURLResponse) in
                (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status,
                                                  httpVersion: nil, headerFields: nil)!)
            }
            let path = request.url!.path
            if path.contains("device/register") {
                return respond(200, #"{"deviceId":"d","deviceToken":"t","mode":"mock"}"#)
            }
            if path.contains("sync/pull") {
                return respond(200, bodies.next() ?? Self.emptyJSON)
            }
            return respond(404, "{}")
        }
        return BackendClient(baseURL: URL(string: "http://test")!,
                             tokenStore: MemoryDeviceToken(), transport: transport,
                             byteStream: { _ in AsyncThrowingStream { _ in } })
    }

    private func makeEngine(bodies: [String], cursors: CursorStoring = MemoryCursorStore())
        throws -> (RealtimeSyncEngine, OsmoStore, Box) {
        let store = try OsmoStore.inMemory()
        let box = Box(bodies)
        let engine = RealtimeSyncEngine(store: store, client: makeClient(box),
                                        cursorStore: cursors,
                                        iMessageDBPath: URL(fileURLWithPath: "/nonexistent"))
        return (engine, store, box)
    }

    private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    // MARK: - Orphan / malformed rows

    @Test("a message referencing a thread in neither the batch nor the store is dropped, not fatal")
    func orphanMessageDoesNotPoisonBatch() async throws {
        let now = iso(Date())
        // One good thread+message, one message pointing at a thread that does
        // not exist anywhere. The FK on message.threadID rejects the orphan; the
        // rest of the batch must still land.
        let batch = """
        {"contacts":[{"platform":"linkedin","handle":"h1","displayName":"Ada","isMe":false}],
         "threads":[{"platform":"linkedin","platformThreadID":"chat-1","title":"Ada","isGroup":false}],
         "messages":[
           {"platform":"linkedin","platformMessageID":"m-good","platformThreadID":"chat-1",
            "senderHandle":"h1","isFromMe":false,"text":"hello","sentAt":"\(now)","readAt":null},
           {"platform":"linkedin","platformMessageID":"m-orphan","platformThreadID":"chat-GONE",
            "senderHandle":"h1","isFromMe":false,"text":"lost","sentAt":"\(now)","readAt":null}],
         "cursor":"2","hasMore":false}
        """.replacingOccurrences(of: "\n", with: "")
        let (engine, store, _) = try makeEngine(bodies: [batch])

        await engine.pullNow()
        #expect(try store.messageCount() == 1)          // the good one
        #expect(try store.threadCount() == 1)
        #expect(try store.search("lost").isEmpty)       // the orphan is nowhere
    }

    @Test("a contact with an empty handle is skipped; its message survives with no sender")
    func emptyHandleContact() async throws {
        let now = iso(Date())
        let batch = """
        {"contacts":[{"platform":"linkedin","handle":"","displayName":"Ghost","isMe":false},
                     {"platform":"linkedin","handle":"  ","displayName":"Spacey","isMe":false}],
         "threads":[{"platform":"linkedin","platformThreadID":"chat-1","title":"?","isGroup":false}],
         "messages":[{"platform":"linkedin","platformMessageID":"m-1","platformThreadID":"chat-1",
                      "senderHandle":"","isFromMe":false,"text":"who am i","sentAt":"\(now)","readAt":null}],
         "cursor":"2","hasMore":false}
        """.replacingOccurrences(of: "\n", with: "")
        let (engine, store, _) = try makeEngine(bodies: [batch])

        await engine.pullNow()
        #expect(try store.contacts().isEmpty)           // both junk contacts skipped
        let msgs = try store.messages(inThread: OsmoThread.makeID(platform: .linkedin,
                                                                  platformThreadID: "chat-1"))
        #expect(msgs.count == 1)                        // message NOT lost to an FK on a ghost sender
        #expect(msgs.first?.senderContactID == nil)
    }

    @Test("normalizer reports skipped-invalid separately from unknown-platform")
    func normalizerSkipCounters() throws {
        let wire = WireBatch(
            contacts: [WireContact(platform: "linkedin", handle: "", displayName: nil, avatarUrl: nil, isMe: false),
                       WireContact(platform: "telegram", handle: "tg-1", displayName: nil, avatarUrl: nil, isMe: false),
                       WireContact(platform: "linkedin", handle: "ok", displayName: nil, avatarUrl: nil, isMe: false)],
            threads: [], messages: [], cursor: "1", hasMore: false)
        let result = BackendBatchNormalizer.normalize(wire)
        #expect(result.batch.contacts.count == 1)
        #expect(result.skippedInvalid == 1)
        #expect(result.skippedUnknownPlatform == 1)
    }

    @Test("duplicate platformMessageIDs inside one batch collapse to a single row (last content wins)")
    func duplicateIDsInOneBatch() async throws {
        let now = iso(Date())
        let batch = """
        {"contacts":[],"threads":[{"platform":"linkedin","platformThreadID":"chat-1","title":null,"isGroup":false}],
         "messages":[
           {"platform":"linkedin","platformMessageID":"m-dup","platformThreadID":"chat-1",
            "senderHandle":null,"isFromMe":false,"text":"first copy","sentAt":"\(now)","readAt":null},
           {"platform":"linkedin","platformMessageID":"m-dup","platformThreadID":"chat-1",
            "senderHandle":null,"isFromMe":false,"text":"first copy","sentAt":"\(now)","readAt":null},
           {"platform":"linkedin","platformMessageID":"m-dup","platformThreadID":"chat-1",
            "senderHandle":null,"isFromMe":false,"text":"revised copy","sentAt":"\(now)","readAt":null}],
         "cursor":"2","hasMore":false}
        """.replacingOccurrences(of: "\n", with: "")
        let (engine, store, _) = try makeEngine(bodies: [batch])

        await engine.pullNow()
        #expect(try store.messageCount() == 1)
        let msg = try store.messages(inThread: OsmoThread.makeID(platform: .linkedin,
                                                                 platformThreadID: "chat-1")).first
        #expect(msg?.text == "revised copy")
    }

    @Test("a sentAt in the future ingests once, idempotently — no crash, no duplicate")
    func futureSentAt() async throws {
        let future = iso(Date().addingTimeInterval(365 * 86_400))
        let batch = """
        {"contacts":[],"threads":[{"platform":"linkedin","platformThreadID":"chat-1","title":null,"isGroup":false}],
         "messages":[{"platform":"linkedin","platformMessageID":"m-f","platformThreadID":"chat-1",
                      "senderHandle":null,"isFromMe":false,"text":"from the future","sentAt":"\(future)","readAt":null}],
         "cursor":"2","hasMore":false}
        """.replacingOccurrences(of: "\n", with: "")
        let cursors = MemoryCursorStore()
        let (engine, store, _) = try makeEngine(bodies: [batch, batch], cursors: cursors)

        await engine.pullNow()
        #expect(try store.messageCount() == 1)
        cursors.saveBackendCursor("")                   // force a full re-pull of the same content
        await engine.pullNow()
        #expect(try store.messageCount() == 1)          // deterministic id dedups
    }

    @Test("a reaction whose target message never landed: no crash, no orphan visible in the thread")
    func reactionOnMissingMessage() async throws {
        let now = iso(Date())
        // The reaction rides on a message whose thread is missing — the message
        // is FK-dropped, so the reaction's target does not exist in the store.
        let batch = """
        {"contacts":[],"threads":[{"platform":"linkedin","platformThreadID":"chat-real","title":null,"isGroup":false}],
         "messages":[
           {"platform":"linkedin","platformMessageID":"m-1","platformThreadID":"chat-real",
            "senderHandle":null,"isFromMe":false,"text":"visible","sentAt":"\(now)","readAt":null},
           {"platform":"linkedin","platformMessageID":"m-ghost","platformThreadID":"chat-GONE",
            "senderHandle":null,"isFromMe":false,"text":"dropped","sentAt":"\(now)","readAt":null,
            "reactions":[{"emoji":"❤️","senderHandle":"h9","isFromMe":false}]}],
         "cursor":"2","hasMore":false}
        """.replacingOccurrences(of: "\n", with: "")
        let (engine, store, _) = try makeEngine(bodies: [batch])

        await engine.pullNow()
        let threadID = OsmoThread.makeID(platform: .linkedin, platformThreadID: "chat-real")
        #expect(try store.messages(inThread: threadID).count == 1)
        // The orphan reaction must not surface anywhere a transcript reads.
        #expect(try store.reactions(inThread: threadID).isEmpty)
    }

    // MARK: - Epoch flapping

    @Test("epoch flap A→B→A: at most ONE reset per pullNow, cursor converges, no reset loop")
    func epochFlapDoesNotLoop() async throws {
        let now = iso(Date())
        func page(epoch: String, cursor: String, maxSeq: Int, msg: String?) -> String {
            let messages = msg.map {
                #"[{"platform":"linkedin","platformMessageID":"\#($0)","platformThreadID":"chat-1","senderHandle":null,"isFromMe":false,"text":"hi","sentAt":"\#(now)","readAt":null}]"#
            } ?? "[]"
            return #"{"contacts":[],"threads":[{"platform":"linkedin","platformThreadID":"chat-1","title":null,"isGroup":false}],"messages":\#(messages),"cursor":"\#(cursor)","hasMore":false,"epoch":"\#(epoch)","maxSeq":\#(maxSeq)}"#
        }
        let cursors = MemoryCursorStore()
        cursors.saveBackendCursor("7")
        cursors.saveBackendEpoch("ep-A")
        // Pull 1: backend answers under epoch B → reset once, replay lands m-1.
        // Pull 2: backend flaps back to epoch A → reset once, replay is idempotent.
        // Pull 3: still epoch A, matching cursor → NO reset, no extra request.
        let bodies = [
            page(epoch: "ep-B", cursor: "7", maxSeq: 2, msg: nil),      // pull 1, stale echo
            page(epoch: "ep-B", cursor: "2", maxSeq: 2, msg: "m-1"),    // pull 1, replay after reset
            page(epoch: "ep-A", cursor: "2", maxSeq: 2, msg: nil),      // pull 2, flap back
            page(epoch: "ep-A", cursor: "2", maxSeq: 2, msg: "m-1"),    // pull 2, replay after reset
            page(epoch: "ep-A", cursor: "2", maxSeq: 2, msg: nil),      // pull 3, steady state
        ]
        let (engine, store, box) = try makeEngine(bodies: bodies, cursors: cursors)

        await engine.pullNow()
        #expect(box.pulls == 2, "pull 1 must reset exactly once")
        #expect(try store.messageCount() == 1)
        #expect(cursors.loadBackendEpoch() == "ep-B")
        #expect(cursors.loadBackendCursor() == "2")

        await engine.pullNow()
        #expect(box.pulls == 4, "pull 2 must reset exactly once, not loop")
        #expect(try store.messageCount() == 1)          // replay dedups
        #expect(cursors.loadBackendEpoch() == "ep-A")
        #expect(cursors.loadBackendCursor() == "2")

        await engine.pullNow()
        #expect(box.pulls == 5, "steady state: one request, no reset")
        #expect(cursors.loadBackendCursor() == "2")     // converged
    }

    @Test("epoch change with cursor already at zero does not reset (nothing to replay)")
    func epochChangeAtZero() async throws {
        let now = iso(Date())
        let body = #"{"contacts":[],"threads":[{"platform":"linkedin","platformThreadID":"c","title":null,"isGroup":false}],"messages":[{"platform":"linkedin","platformMessageID":"m","platformThreadID":"c","senderHandle":null,"isFromMe":false,"text":"x","sentAt":"\#(now)","readAt":null}],"cursor":"1","hasMore":false,"epoch":"ep-NEW","maxSeq":1}"#
        let cursors = MemoryCursorStore()
        cursors.saveBackendEpoch("ep-OLD")              // cursor is "" (fresh install shape)
        let (engine, store, box) = try makeEngine(bodies: [body], cursors: cursors)

        await engine.pullNow()
        #expect(box.pulls == 1)                          // no second request
        #expect(try store.messageCount() == 1)
        #expect(cursors.loadBackendEpoch() == "ep-NEW")  // adopted, not looped
    }
}
