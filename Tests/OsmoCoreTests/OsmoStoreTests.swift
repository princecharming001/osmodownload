import Testing
import Foundation
@testable import OsmoCore

@Suite("OsmoStore — encrypted schema, dedup, FTS (P0.3)")
struct OsmoStoreTests {

    private func newStore() throws -> OsmoStore { try OsmoStore.inMemory() }

    private func thread(_ platform: Platform = .imessage,
                        _ pid: String = "chat-1") -> OsmoThread {
        OsmoThread(id: OsmoThread.makeID(platform: platform, platformThreadID: pid),
                   updatedAt: Date(timeIntervalSince1970: 0), deviceSeq: 0,
                   platform: platform, platformThreadID: pid, title: nil, isGroup: false)
    }

    private func message(_ threadID: UUID, _ pid: String, text: String,
                         readAt: Date? = nil, from me: Bool = false,
                         platform: Platform = .imessage) -> OsmoMessage {
        OsmoMessage(id: OsmoMessage.makeID(platform: platform, platformMessageID: pid),
                    updatedAt: Date(timeIntervalSince1970: 0), deviceSeq: 0,
                    platform: platform, platformMessageID: pid, threadID: threadID,
                    isFromMe: me, text: text, sentAt: Date(timeIntervalSince1970: 1000),
                    readAt: readAt)
    }

    @Test("A message round-trips into the store and is retrievable")
    func roundTrip() throws {
        let store = try newStore()
        let t = thread()
        try store.ingest(t)
        try store.ingest(message(t.id, "m1", text: "are you free friday"))
        #expect(try store.threadCount() == 1)
        #expect(try store.messageCount() == 1)
        let msgs = try store.messages(inThread: t.id)
        #expect(msgs.count == 1)
        #expect(msgs.first?.text == "are you free friday")
    }

    @Test("Re-ingesting an identical message is a no-op (no sync churn)")
    func dedupUnchanged() throws {
        let store = try newStore()
        let t = thread(); try store.ingest(t)
        let m = message(t.id, "m1", text: "hey")
        #expect(try store.ingest(m) == true)          // first write
        let after1 = try store.messages(inThread: t.id).first!
        #expect(try store.ingest(m) == false)         // identical → skipped
        let after2 = try store.messages(inThread: t.id).first!
        #expect(after1.deviceSeq == after2.deviceSeq) // clock did not advance
        #expect(after1.updatedAt == after2.updatedAt)
    }

    @Test("A changed message (e.g. read receipt arrives) re-writes with a fresh clock")
    func changedRewrites() throws {
        let store = try newStore()
        let t = thread(); try store.ingest(t)
        try store.ingest(message(t.id, "m1", text: "hey"))
        let before = try store.messages(inThread: t.id).first!
        // Same message id, now with a read timestamp → content changed.
        #expect(try store.ingest(message(t.id, "m1", text: "hey",
                                         readAt: Date(timeIntervalSince1970: 2000))) == true)
        let after = try store.messages(inThread: t.id).first!
        #expect(after.readAt != nil)
        #expect(after.deviceSeq > before.deviceSeq)   // clock advanced
    }

    @Test("Soft-delete tombstones the row and removes it from search + counts")
    func softDelete() throws {
        let store = try newStore()
        let t = thread(); try store.ingest(t)
        let m = message(t.id, "m1", text: "delete me please")
        try store.ingest(m)
        #expect(try store.messageCount() == 1)
        try store.softDelete(OsmoMessage.self, id: m.id)
        #expect(try store.messageCount() == 0)
        #expect(try store.search("delete").isEmpty)
    }

    @Test("Unified FTS search finds messages across platforms")
    func ftsSearch() throws {
        let store = try newStore()
        let t1 = thread(.imessage, "c1"); try store.ingest(t1)
        let t2 = thread(.slack, "c2"); try store.ingest(t2)
        try store.ingest(message(t1.id, "m1", text: "lunch on friday sounds great"))
        try store.ingest(message(t2.id, "m2", text: "can you review the friday deploy",
                                  platform: .slack))
        try store.ingest(message(t1.id, "m3", text: "totally unrelated"))
        let hits = try store.search("friday")
        #expect(hits.count == 2)
        let platforms = Set(hits.map(\.platform))
        #expect(platforms == [.imessage, .slack])
        // Prefix matching: "fri" finds "friday".
        #expect(try store.search("fri").count == 2)
    }

    @Test("FTS sanitizer neutralizes punctuation without MATCH errors")
    func ftsSanitize() throws {
        let store = try newStore()
        let t = thread(); try store.ingest(t)
        try store.ingest(message(t.id, "m1", text: "meet at 5pm?? (the usual spot)"))
        #expect(try store.search("usual").count == 1)
        #expect(try store.search("!!!").isEmpty)      // punctuation-only → no crash, no hits
        #expect(OsmoStore.sanitizeFTS("a, b! c").contains("\"a\"*"))
    }

    @Test("Deterministic IDs are stable across calls (cross-device dedup)")
    func deterministicIDs() throws {
        let a = OsmoMessage.makeID(platform: .imessage, platformMessageID: "GUID-123")
        let b = OsmoMessage.makeID(platform: .imessage, platformMessageID: "GUID-123")
        let c = OsmoMessage.makeID(platform: .slack, platformMessageID: "GUID-123")
        #expect(a == b)          // same platform+guid → same id
        #expect(a != c)          // platform is part of the key
        // Valid v5 UUID (version nibble == 5).
        #expect(a.uuidString.split(separator: "-")[2].first == "5")
    }

    @Test("Platform send-capability split matches the plan")
    func sendCapability() {
        #expect(Platform.imessage.supportsDirectSend)
        #expect(Platform.gmail.supportsDirectSend)
        #expect(Platform.slack.supportsDirectSend)
        #expect(!Platform.linkedin.supportsDirectSend)   // draft-and-insert only
        #expect(!Platform.instagram.supportsDirectSend)
        #expect(Platform.linkedin.access == .overlayOnly)
    }
}
