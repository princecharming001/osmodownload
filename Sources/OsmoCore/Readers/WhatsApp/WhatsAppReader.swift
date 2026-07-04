import Foundation
import GRDB

/// WhatsApp's on-device message store is plaintext-at-rest SQLite (verified July
/// 2026 — "E2E means unreadable locally" is false). This reads it read-only.
///
/// Schema note: modeled on the documented `msgstore` `messages` table
/// (`key_remote_jid`, `key_from_me`, `data`, `timestamp`). The macOS WhatsApp
/// client's `ChatStorage.sqlite` differs and needs a field mapping verified
/// against a real install before shipping — that mapping lives here and nowhere
/// else, and the reader + normalizer + importer are already tested against a
/// fixture of this shape.
public struct RawWAMessage: Equatable, Sendable {
    public var rowID: Int64
    public var jid: String          // key_remote_jid, e.g. 15551234567@s.whatsapp.net / …@g.us
    public var fromMe: Bool
    public var text: String
    public var timestampMS: Int64
}

public struct WhatsAppReader: Sendable {
    private let dbQueue: DatabaseQueue

    public init(path: URL) throws {
        var config = Configuration()
        config.readonly = true
        self.dbQueue = try DatabaseQueue(path: path.path, configuration: config)
    }

    public func readAll() throws -> [RawWAMessage] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT _id, key_remote_jid, key_from_me, data, timestamp
                FROM messages
                WHERE data IS NOT NULL AND data <> ''
                ORDER BY timestamp ASC
                """).map { row in
                RawWAMessage(rowID: row["_id"], jid: row["key_remote_jid"],
                             fromMe: (row["key_from_me"] as Int64) != 0,
                             text: row["data"], timestampMS: row["timestamp"])
            }
        }
    }
}

public enum WhatsAppNormalizer {
    private static let platform = Platform.whatsapp

    public static func normalize(_ raws: [RawWAMessage]) -> NormalizedBatch {
        var contacts: [UUID: OsmoContact] = [:]
        var threads: [UUID: OsmoThread] = [:]
        var out: [OsmoMessage] = []
        let epoch = Date(timeIntervalSince1970: 0)

        for r in raws {
            let isGroup = r.jid.hasSuffix("@g.us")
            let threadID = OsmoThread.makeID(platform: platform, platformThreadID: r.jid)
            let sentAt = Date(timeIntervalSince1970: Double(r.timestampMS) / 1000)
            if var t = threads[threadID] {
                if sentAt > (t.lastMessageAt ?? .distantPast) { t.lastMessageAt = sentAt; threads[threadID] = t }
            } else {
                threads[threadID] = OsmoThread(id: threadID, updatedAt: epoch, deviceSeq: 0,
                                               platform: platform, platformThreadID: r.jid,
                                               title: nil, isGroup: isGroup, lastMessageAt: sentAt)
            }
            // For a 1:1 the jid's number is the contact handle.
            var senderContactID: UUID?
            if !r.fromMe, !isGroup {
                let number = String(r.jid.prefix { $0 != "@" })
                let cid = OsmoContact.makeID(platform: platform, handle: number)
                if contacts[cid] == nil {
                    contacts[cid] = OsmoContact(id: cid, updatedAt: epoch, deviceSeq: 0,
                                                platform: platform, handle: number, isMe: false)
                }
                senderContactID = cid
            }
            let mid = "\(r.jid):\(r.rowID)"
            out.append(OsmoMessage(
                id: OsmoMessage.makeID(platform: platform, platformMessageID: mid),
                updatedAt: epoch, deviceSeq: 0, platform: platform, platformMessageID: mid,
                threadID: threadID, senderContactID: senderContactID, isFromMe: r.fromMe,
                text: r.text, sentAt: sentAt))
        }
        return NormalizedBatch(contacts: Array(contacts.values),
                               threads: Array(threads.values), messages: out)
    }
}

public struct WhatsAppImporter: Sendable {
    public init() {}
    @discardableResult
    public func importAll(from dbURL: URL, into store: OsmoStore) throws -> ImportStats {
        let batch = WhatsAppNormalizer.normalize(try WhatsAppReader(path: dbURL).readAll())
        for c in batch.contacts { try store.ingest(c) }
        for t in batch.threads { try store.ingest(t) }
        var newly = 0
        for m in batch.messages where try store.ingest(m) { newly += 1 }
        return ImportStats(threads: batch.threads.count, contacts: batch.contacts.count,
                           messages: batch.messages.count, newlyIngested: newly)
    }
}
