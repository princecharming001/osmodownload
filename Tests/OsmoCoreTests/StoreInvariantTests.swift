import Testing
import Foundation
import GRDB
@testable import OsmoCore

/// Store-level invariants: reciprocity-scan degenerate shapes, its performance
/// on a 5k-thread store (the v13 indexes' contract), and hammer-idempotency of
/// `ingest`.
@Suite("Store invariants — reciprocity scan shapes, 5k-thread perf, ingest idempotency")
struct StoreInvariantTests {

    private func thread(_ pid: String, group: Bool = false) -> OsmoThread {
        OsmoThread(id: OsmoThread.makeID(platform: .imessage, platformThreadID: pid),
                   updatedAt: Date(timeIntervalSince1970: 0), deviceSeq: 0,
                   platform: .imessage, platformThreadID: pid, title: nil, isGroup: group)
    }
    private func contact(_ handle: String, isMe: Bool = false) -> OsmoContact {
        OsmoContact(id: OsmoContact.makeID(platform: .imessage, handle: handle),
                    updatedAt: Date(timeIntervalSince1970: 0), deviceSeq: 0,
                    platform: .imessage, handle: handle, isMe: isMe)
    }
    private func message(_ pid: String, thread: UUID, sender: UUID? = nil,
                         fromMe: Bool = false, text: String = "hi") -> OsmoMessage {
        OsmoMessage(id: OsmoMessage.makeID(platform: .imessage, platformMessageID: pid),
                    updatedAt: Date(timeIntervalSince1970: 0), deviceSeq: 0,
                    platform: .imessage, platformMessageID: pid, threadID: thread,
                    senderContactID: sender, isFromMe: fromMe, text: text,
                    sentAt: Date(timeIntervalSince1970: 1000))
    }

    @Test("outboundCounterpartyHandles on an empty store is an empty set, not an error")
    func reciprocityOnEmptyStore() throws {
        let store = try OsmoStore.inMemory()
        #expect(try store.outboundCounterpartyHandles().isEmpty)
    }

    @Test("a store with ONLY group threads yields no outbound counterparties")
    func reciprocityGroupsOnly() throws {
        let store = try OsmoStore.inMemory()
        let me = contact("me@self.test", isMe: true)
        let pal = contact("+15551230001")
        try store.ingest(me); try store.ingest(pal)
        for i in 0..<3 {
            let g = thread("group-\(i)", group: true)
            try store.ingest(g)
            try store.ingest(message("g\(i)-in", thread: g.id, sender: pal.id))
            try store.ingest(message("g\(i)-out", thread: g.id, sender: me.id, fromMe: true))
        }
        #expect(try store.outboundCounterpartyHandles().isEmpty)
    }

    @Test("reciprocity scan over a 5k-thread store stays fast (v13 indexes)")
    func reciprocityScanAtScale() throws {
        let store = try OsmoStore.inMemory()
        // Seed 5k threads / 5k contacts / 10k messages in one raw transaction —
        // going through ingest() would dominate the test with 15k write txns.
        try store.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO contact (id, updatedAt, deviceSeq, platform, handle, isMe) VALUES (?, ?, 0, 'imessage', 'me@self.test', 1)",
                           arguments: [UUID().uuidString, Date()])
            let meID = try String.fetchOne(db, sql: "SELECT id FROM contact LIMIT 1")!
            for i in 0..<5000 {
                let cid = UUID().uuidString
                let tid = UUID().uuidString
                try db.execute(sql: "INSERT INTO contact (id, updatedAt, deviceSeq, platform, handle, isMe) VALUES (?, ?, 0, 'imessage', ?, 0)",
                               arguments: [cid, Date(), "+1555\(String(format: "%07d", i))"])
                try db.execute(sql: "INSERT INTO thread (id, updatedAt, deviceSeq, platform, platformThreadID, isGroup) VALUES (?, ?, 0, 'imessage', ?, 0)",
                               arguments: [tid, Date(), "chat-\(i)"])
                try db.execute(sql: "INSERT INTO message (id, updatedAt, deviceSeq, platform, platformMessageID, threadID, senderContactID, isFromMe, text, sentAt) VALUES (?, ?, 0, 'imessage', ?, ?, ?, 0, 'hey', ?)",
                               arguments: [UUID().uuidString, Date(), "m-\(i)-in", tid, cid, Date()])
                // Every third thread has an outbound reply → counts.
                if i % 3 == 0 {
                    try db.execute(sql: "INSERT INTO message (id, updatedAt, deviceSeq, platform, platformMessageID, threadID, senderContactID, isFromMe, text, sentAt) VALUES (?, ?, 0, 'imessage', ?, ?, ?, 1, 'yo', ?)",
                                   arguments: [UUID().uuidString, Date(), "m-\(i)-out", tid, meID, Date()])
                }
            }
        }

        let clock = ContinuousClock()
        var handles: Set<String> = []
        let elapsed = try clock.measure { handles = try store.outboundCounterpartyHandles() }
        #expect(handles.count == 1667)                   // ceil(5000/3) replied threads
        // Target is <100ms on the v13 indexes; the bound is generous for CI noise.
        #expect(elapsed < .milliseconds(500), "reciprocity scan took \(elapsed)")
    }

    @Test("ingesting the identical message 50x leaves ONE row and never advances the clock")
    func hammerIdempotency() throws {
        let store = try OsmoStore.inMemory()
        let t = thread("chat-1"); try store.ingest(t)
        let m = message("m-1", thread: t.id, text: "hello there")
        #expect(try store.ingest(m) == true)
        let first = try store.messages(inThread: t.id).first!
        for _ in 0..<49 {
            #expect(try store.ingest(m) == false)        // every re-ingest is a no-op
        }
        let rows = try store.messages(inThread: t.id)
        #expect(rows.count == 1)
        #expect(rows.first?.deviceSeq == first.deviceSeq)
        #expect(rows.first?.updatedAt == first.updatedAt)
        #expect(try store.messageCount() == 1)
        // FTS stayed in lockstep — still exactly one hit.
        #expect(try store.search("hello").count == 1)
    }
}
