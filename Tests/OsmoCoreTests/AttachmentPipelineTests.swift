import Testing
import Foundation
import GRDB
@testable import OsmoCore

@Suite("OsmoAttachment — model, migration, ingest")
struct OsmoAttachmentModelTests {
    @Test("makeID is deterministic per (platform, message, attachmentRef)")
    func makeIDDeterministic() {
        let a = OsmoAttachment.makeID(platform: .gmail, platformMessageID: "m1", attachmentRef: "att-1")
        let b = OsmoAttachment.makeID(platform: .gmail, platformMessageID: "m1", attachmentRef: "att-1")
        let c = OsmoAttachment.makeID(platform: .gmail, platformMessageID: "m1", attachmentRef: "att-2")
        #expect(a == b)
        #expect(a != c)
    }

    @Test("preservingEnrichment keeps a cached localPath/thumbnailData when the incoming row has neither")
    func preservesCache() {
        let stored = OsmoAttachment(id: UUID(), updatedAt: .distantPast, deviceSeq: 0,
                                    messageID: UUID(), kind: .image, localPath: "/tmp/cached.jpg",
                                    thumbnailData: Data([1, 2, 3]))
        let incoming = OsmoAttachment(id: stored.id, updatedAt: Date(), deviceSeq: 1,
                                      messageID: stored.messageID, kind: .image)
        let merged = incoming.preservingEnrichment(from: stored)
        #expect(merged.localPath == "/tmp/cached.jpg")
        #expect(merged.thumbnailData == Data([1, 2, 3]))
    }

    @Test("A fresh store creates the message_attachment table (v12) and round-trips a row via ingest")
    func migrationAndIngestRoundTrip() throws {
        let store = try OsmoStore.inMemory()
        let threadID = OsmoThread.makeID(platform: .gmail, platformThreadID: "t1")
        let messageID = OsmoMessage.makeID(platform: .gmail, platformMessageID: "m1")
        try store.dbQueue.write { db in
            try OsmoThread(id: threadID, updatedAt: .distantPast, deviceSeq: 0,
                          platform: .gmail, platformThreadID: "t1").save(db)
            try OsmoMessage(id: messageID, updatedAt: .distantPast, deviceSeq: 0,
                           platform: .gmail, platformMessageID: "m1", threadID: threadID,
                           isFromMe: false, text: "see attached", sentAt: Date()).save(db)
        }
        let attachmentID = OsmoAttachment.makeID(platform: .gmail, platformMessageID: "m1", attachmentRef: "att-1")
        let att = OsmoAttachment(id: attachmentID, updatedAt: .distantPast, deviceSeq: 0,
                                 messageID: messageID, kind: .file, filename: "invoice.pdf",
                                 sizeBytes: 4821, remoteRef: "att-1")
        #expect(try store.ingest(att) == true)
        let byMessage = try store.attachments(inThread: threadID)
        #expect(byMessage[messageID]?.count == 1)
        #expect(byMessage[messageID]?.first?.filename == "invoice.pdf")
    }

    @Test("cacheAttachmentMedia writes localPath/thumbnailData without advancing the sync clock")
    func cacheMediaDoesNotAdvanceClock() throws {
        let store = try OsmoStore.inMemory()
        let threadID = OsmoThread.makeID(platform: .gmail, platformThreadID: "t2")
        let messageID = OsmoMessage.makeID(platform: .gmail, platformMessageID: "m2")
        try store.dbQueue.write { db in
            try OsmoThread(id: threadID, updatedAt: .distantPast, deviceSeq: 0,
                          platform: .gmail, platformThreadID: "t2").save(db)
            try OsmoMessage(id: messageID, updatedAt: .distantPast, deviceSeq: 0,
                           platform: .gmail, platformMessageID: "m2", threadID: threadID,
                           isFromMe: false, text: "photo", sentAt: Date()).save(db)
        }
        let attachmentID = OsmoAttachment.makeID(platform: .gmail, platformMessageID: "m2", attachmentRef: "att-2")
        let att = OsmoAttachment(id: attachmentID, updatedAt: .distantPast, deviceSeq: 5,
                                 messageID: messageID, kind: .image, remoteRef: "att-2")
        try store.ingest(att)
        let beforeSeq = (try store.attachments(inThread: threadID))[messageID]?.first?.deviceSeq

        try store.cacheAttachmentMedia(id: attachmentID, localPath: "/tmp/x.jpg", thumbnailData: Data([9]))
        let after = (try store.attachments(inThread: threadID))[messageID]?.first
        #expect(after?.localPath == "/tmp/x.jpg")
        #expect(after?.thumbnailData == Data([9]))
        #expect(after?.deviceSeq == beforeSeq)   // unchanged — a cache fill isn't a sync event
    }
}

@Suite("BackendBatchNormalizer — attachment mapping")
struct BackendBatchNormalizerAttachmentTests {
    @Test("Maps a WireAttachment onto its message, deterministic id, kind from rawValue")
    func mapsAttachment() {
        let wire = WireBatch(
            contacts: [],
            threads: [WireThread(platform: "gmail", platformThreadID: "t1", title: nil,
                                 isGroup: false, lastMessageAt: Date())],
            messages: [WireMessage(platform: "gmail", platformMessageID: "m1", platformThreadID: "t1",
                                   senderHandle: "a@b.com", isFromMe: false, text: "see attached",
                                   sentAt: Date(), readAt: nil,
                                   attachments: [WireAttachment(id: "att-1", kind: "file",
                                                                mimeType: "application/pdf",
                                                                filename: "invoice.pdf", sizeBytes: 4821,
                                                                remoteRef: "att-1")])],
            cursor: "1", hasMore: false)
        let result = BackendBatchNormalizer.normalize(wire)
        #expect(result.batch.attachmentAdds.count == 1)
        let att = result.batch.attachmentAdds[0]
        #expect(att.kind == .file)
        #expect(att.filename == "invoice.pdf")
        #expect(att.messageID == OsmoMessage.makeID(platform: .gmail, platformMessageID: "m1"))
        #expect(att.id == OsmoAttachment.makeID(platform: .gmail, platformMessageID: "m1", attachmentRef: "att-1"))
    }

    @Test("A link-kind attachment carries linkURL/title and no remoteRef")
    func linkAttachment() {
        let wire = WireBatch(
            contacts: [],
            threads: [WireThread(platform: "instagram", platformThreadID: "t2", title: nil,
                                 isGroup: false, lastMessageAt: Date())],
            messages: [WireMessage(platform: "instagram", platformMessageID: "m2", platformThreadID: "t2",
                                   senderHandle: "x", isFromMe: false, text: "check this out",
                                   sentAt: Date(), readAt: nil,
                                   attachments: [WireAttachment(id: "p1", kind: "link",
                                                                url: "https://instagram.com/p/xyz",
                                                                title: "A reel")])],
            cursor: "1", hasMore: false)
        let result = BackendBatchNormalizer.normalize(wire)
        let att = result.batch.attachmentAdds[0]
        #expect(att.kind == .link)
        #expect(att.linkURL == "https://instagram.com/p/xyz")
        #expect(att.title == "A reel")
        #expect(att.remoteRef == nil)
    }
}

@Suite("IMessageNormalizer — attachment mapping")
struct IMessageNormalizerAttachmentTests {
    @Test("Maps a RawAttachment onto its message with an immediately-set, tilde-expanded local path")
    func mapsLocalAttachment() {
        let raw = RawIMessage(guid: "G1", text: "", isFromMe: false, dateRaw: 0, dateReadRaw: 0,
                              handle: "+15551234567", chatGUID: "iMessage;-;+15551234567",
                              chatIdentifier: "+15551234567", chatDisplayName: nil, chatStyle: 45,
                              attachments: [RawAttachment(guid: "AG1",
                                                          filename: "~/Library/Messages/Attachments/ab/photo.heic",
                                                          mimeType: "image/heic", transferName: "photo.heic",
                                                          totalBytes: 12345)])
        let batch = IMessageNormalizer.normalize([raw])
        #expect(batch.attachmentAdds.count == 1)
        let att = batch.attachmentAdds[0]
        #expect(att.kind == .image)
        #expect(att.filename == "photo.heic")
        #expect(att.sizeBytes == 12345)
        // iMessage attachments are already local — no fetch needed, localPath is
        // set at normalize time (not left for a later lazy fetch).
        #expect(att.localPath == NSHomeDirectory() + "/Library/Messages/Attachments/ab/photo.heic")
    }

    @Test("A message with no attachments yields no attachment rows")
    func noAttachments() {
        let raw = RawIMessage(guid: "G2", text: "hi", isFromMe: false, dateRaw: 0, dateReadRaw: 0,
                              handle: "+15551234567", chatGUID: "iMessage;-;+15551234567",
                              chatIdentifier: "+15551234567", chatDisplayName: nil, chatStyle: 45)
        #expect(IMessageNormalizer.normalize([raw]).attachmentAdds.isEmpty)
    }
}

@Suite("ChatDBReader — attachment batched join")
struct ChatDBReaderAttachmentTests {
    private func makeFixtureDB(withAttachmentTables: Bool) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osmo-attach-fixture-\(UUID().uuidString).db")
        let db = try DatabaseQueue(path: url.path)
        try db.write { db in
            try db.execute(sql: "CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT)")
            try db.execute(sql: """
                CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, chat_identifier TEXT,
                                   display_name TEXT, style INTEGER)
                """)
            try db.execute(sql: """
                CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT,
                                      handle_id INTEGER, is_from_me INTEGER, date INTEGER, date_read INTEGER,
                                      cache_has_attachments INTEGER DEFAULT 0)
                """)
            try db.execute(sql: "CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER)")

            try db.execute(sql: "INSERT INTO handle (ROWID, id) VALUES (1, '+15551234567')")
            try db.execute(sql: """
                INSERT INTO chat (ROWID, guid, chat_identifier, display_name, style)
                VALUES (1, 'iMessage;-;+15551234567', '+15551234567', NULL, 45)
                """)
            // Message 1 is attachment-only (empty text, cache_has_attachments=1)
            // with TWO attachments (must not multiply its row); message 2 is a
            // normal text message with none.
            try db.execute(sql: """
                INSERT INTO message (ROWID, guid, text, handle_id, is_from_me, date, date_read, cache_has_attachments)
                VALUES (1, 'G1', '', 1, 0, 0, 0, 1), (2, 'G2', 'no attachments here', 1, 0, 100, 0, 0)
                """)
            try db.execute(sql: "INSERT INTO chat_message_join (chat_id, message_id) VALUES (1,1),(1,2)")

            if withAttachmentTables {
                try db.execute(sql: """
                    CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY, guid TEXT, filename TEXT,
                                             mime_type TEXT, transfer_name TEXT, total_bytes INTEGER)
                    """)
                try db.execute(sql: "CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER)")
                try db.execute(sql: """
                    INSERT INTO attachment (ROWID, guid, filename, mime_type, transfer_name, total_bytes)
                    VALUES (1, 'AG1', '/tmp/photo.heic', 'image/heic', 'photo.heic', 500),
                           (2, 'AG2', '/tmp/clip.mov', 'video/quicktime', 'clip.mov', 900)
                    """)
                try db.execute(sql: "INSERT INTO message_attachment_join (message_id, attachment_id) VALUES (1,1),(1,2)")
            }
        }
        return url
    }

    @Test("readAll attaches multiple attachments to their message without duplicating the message row")
    func attachesWithoutMultiplying() throws {
        let url = try makeFixtureDB(withAttachmentTables: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let rows = try ChatDBReader(path: url).readAll()
        #expect(rows.count == 2)   // NOT 3 — two attachments must not multiply message 1's row
        let m1 = rows.first { $0.guid == "G1" }
        let m2 = rows.first { $0.guid == "G2" }
        #expect(m1?.attachments.count == 2)
        #expect(Set(m1?.attachments.map(\.guid) ?? []) == ["AG1", "AG2"])
        #expect(m2?.attachments.isEmpty == true)
    }

    @Test("A chat.db without attachment tables degrades to empty attachments, never fails")
    func degradesWithoutAttachmentTables() throws {
        let url = try makeFixtureDB(withAttachmentTables: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let rows = try ChatDBReader(path: url).readAll()
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.attachments.isEmpty })
    }
}
