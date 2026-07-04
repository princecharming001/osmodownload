import Foundation

/// A normalized batch ready to ingest, in FK order (contacts → threads → messages).
public struct NormalizedBatch: Equatable, Sendable {
    public var contacts: [OsmoContact]
    public var threads: [OsmoThread]
    public var messages: [OsmoMessage]
}

/// Maps raw `chat.db` rows into Osmo's canonical schema. Pure and deterministic —
/// unit-testable without a database. Deterministic IDs (from message GUID / chat
/// identifier / handle) mean re-import and a second Mac converge on the same rows.
public enum IMessageNormalizer {
    private static let platform = Platform.imessage

    public static func normalize(_ raws: [RawIMessage]) -> NormalizedBatch {
        var contacts: [UUID: OsmoContact] = [:]
        var threads: [UUID: OsmoThread] = [:]
        var messages: [OsmoMessage] = []
        let epoch = Date(timeIntervalSince1970: 0)   // sync clock is stamped by the store on ingest

        for raw in raws {
            // Thread keyed on chat_identifier (stable across the Tahoe service-prefix
            // change), falling back to the raw chat GUID.
            let threadKey = raw.chatIdentifier ?? raw.chatGUID
            let threadID = OsmoThread.makeID(platform: platform, platformThreadID: threadKey)
            let sentAt = AppleTime.date(fromRaw: raw.dateRaw) ?? epoch

            if var existing = threads[threadID] {
                if sentAt > (existing.lastMessageAt ?? .distantPast) {
                    existing.lastMessageAt = sentAt
                    threads[threadID] = existing
                }
            } else {
                threads[threadID] = OsmoThread(
                    id: threadID, updatedAt: epoch, deviceSeq: 0,
                    platform: platform, platformThreadID: threadKey,
                    title: raw.chatDisplayName?.isEmpty == false ? raw.chatDisplayName : nil,
                    isGroup: raw.chatStyle == 43,
                    lastMessageAt: sentAt)
            }

            // Sender contact (incoming only; from-me has no contact row).
            var senderContactID: UUID?
            if !raw.isFromMe, let handle = raw.handle, !handle.isEmpty {
                let cid = OsmoContact.makeID(platform: platform, handle: handle)
                senderContactID = cid
                if contacts[cid] == nil {
                    contacts[cid] = OsmoContact(
                        id: cid, updatedAt: epoch, deviceSeq: 0,
                        platform: platform, handle: handle,
                        displayName: nil, isMe: false)
                }
            }

            messages.append(OsmoMessage(
                id: OsmoMessage.makeID(platform: platform, platformMessageID: raw.guid),
                updatedAt: epoch, deviceSeq: 0,
                platform: platform, platformMessageID: raw.guid, threadID: threadID,
                senderContactID: senderContactID, isFromMe: raw.isFromMe,
                text: raw.text, sentAt: sentAt,
                readAt: AppleTime.date(fromRaw: raw.dateReadRaw)))
        }

        return NormalizedBatch(
            contacts: Array(contacts.values),
            threads: Array(threads.values),
            messages: messages)
    }
}

/// Stats from an import pass, for the integration-health UI + the P0 gate demo.
public struct ImportStats: Equatable, Sendable {
    public var threads: Int
    public var contacts: Int
    public var messages: Int
    /// How many messages were actually written (new or changed) — dedup skips the rest.
    public var newlyIngested: Int
}

/// Ties reader → normalizer → store for the iMessage platform.
public struct IMessageImporter: Sendable {
    public init() {}

    /// Import every text message from a chat.db into the store (FK-safe order),
    /// returning stats. Idempotent: re-running only writes new/changed rows.
    @discardableResult
    public func importAll(from dbURL: URL, into store: OsmoStore) throws -> ImportStats {
        let raws = try ChatDBReader(path: dbURL).readAll()
        let batch = IMessageNormalizer.normalize(raws)
        for c in batch.contacts { try store.ingest(c) }
        for t in batch.threads { try store.ingest(t) }
        var newly = 0
        for m in batch.messages where try store.ingest(m) { newly += 1 }
        return ImportStats(threads: batch.threads.count, contacts: batch.contacts.count,
                           messages: batch.messages.count, newlyIngested: newly)
    }
}
