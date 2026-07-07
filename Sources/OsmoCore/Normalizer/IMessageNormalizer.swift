import Foundation

/// A normalized batch ready to ingest, in FK order (contacts → threads → messages).
/// Tapback reactions ride alongside as add/remove events (folded onto their target
/// at display time); defaulted empty so non-iMessage normalizers are unaffected.
public struct NormalizedBatch: Equatable, Sendable {
    public var contacts: [OsmoContact]
    public var threads: [OsmoThread]
    public var messages: [OsmoMessage]
    public var reactionAdds: [MessageReaction] = []
    public var reactionRemoves: [UUID] = []
    public var attachmentAdds: [OsmoAttachment] = []
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
        var reactionAdds: [MessageReaction] = []
        var reactionRemoves: [UUID] = []
        var attachmentAdds: [OsmoAttachment] = []
        let epoch = Date(timeIntervalSince1970: 0)   // sync clock is stamped by the store on ingest

        /// Ensure a sender contact exists for an incoming handle; returns its id.
        func senderContact(for handle: String?, isFromMe: Bool) -> UUID? {
            guard !isFromMe, let handle, !handle.isEmpty else { return nil }
            let cid = OsmoContact.makeID(platform: platform, handle: handle)
            if contacts[cid] == nil {
                contacts[cid] = OsmoContact(
                    id: cid, updatedAt: epoch, deviceSeq: 0,
                    platform: platform, handle: handle, displayName: nil, isMe: false)
            }
            return cid
        }

        for raw in raws {
            let sentAt = AppleTime.date(fromRaw: raw.dateRaw) ?? epoch

            // A tapback reaction folds onto its target — it never becomes a bubble.
            if Tapback.isReaction(raw.associatedType), let targetRaw = raw.associatedGuid {
                let targetGuid = ChatDBReader.bareGuid(targetRaw)
                let targetID = OsmoMessage.makeID(platform: platform, platformMessageID: targetGuid)
                let reactorKey = raw.isFromMe ? "me" : (raw.handle ?? "?")
                let kind = Tapback.kind(forAssociatedType: raw.associatedType)
                let type = kind?.type ?? "emoji"
                let emoji = (raw.associatedEmoji?.isEmpty == false ? raw.associatedEmoji! : kind?.emoji) ?? "❔"
                let rid = MessageReaction.makeID(targetGuid: targetGuid, reactorKey: reactorKey, type: type)
                if Tapback.isRemove(raw.associatedType) {
                    reactionRemoves.append(rid)
                } else {
                    reactionAdds.append(MessageReaction(
                        id: rid, targetMessageID: targetID,
                        reactorContactID: senderContact(for: raw.handle, isFromMe: raw.isFromMe),
                        reactionType: type, emoji: emoji, isFromMe: raw.isFromMe, reactedAt: sentAt))
                }
                continue
            }

            // Thread keyed on chat_identifier (stable across the Tahoe service-prefix
            // change), falling back to the raw chat GUID.
            let threadKey = raw.chatIdentifier ?? raw.chatGUID
            let threadID = OsmoThread.makeID(platform: platform, platformThreadID: threadKey)

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

            let replyID = raw.threadOriginatorGuid.map {
                OsmoMessage.makeID(platform: platform, platformMessageID: ChatDBReader.bareGuid($0))
            }
            let messageID = OsmoMessage.makeID(platform: platform, platformMessageID: raw.guid)

            messages.append(OsmoMessage(
                id: messageID,
                updatedAt: epoch, deviceSeq: 0,
                platform: platform, platformMessageID: raw.guid, threadID: threadID,
                senderContactID: senderContact(for: raw.handle, isFromMe: raw.isFromMe),
                isFromMe: raw.isFromMe,
                text: raw.text, sentAt: sentAt,
                readAt: AppleTime.date(fromRaw: raw.dateReadRaw),
                inReplyToMessageID: replyID))

            // iMessage attachments are already local files — no fetch pipeline
            // needed; `localPath` is set immediately (tilde-expanded), and a
            // path chat.db recorded but iCloud has since evicted just means the
            // file won't be at that path when the UI goes to render it (handled
            // as a "not downloaded" state there, not here).
            for att in raw.attachments {
                let path = att.filename.map { ($0 as NSString).expandingTildeInPath }
                attachmentAdds.append(OsmoAttachment(
                    id: OsmoAttachment.makeID(platform: platform, platformMessageID: raw.guid,
                                              attachmentRef: att.guid),
                    updatedAt: epoch, deviceSeq: 0,
                    messageID: messageID, kind: .from(mimeType: att.mimeType),
                    mimeType: att.mimeType,
                    filename: att.transferName ?? (path.map { ($0 as NSString).lastPathComponent }),
                    sizeBytes: att.totalBytes > 0 ? att.totalBytes : nil,
                    remoteRef: att.guid, localPath: path))
            }
        }

        return NormalizedBatch(
            contacts: Array(contacts.values),
            threads: Array(threads.values),
            messages: messages,
            reactionAdds: reactionAdds,
            reactionRemoves: reactionRemoves,
            attachmentAdds: attachmentAdds)
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
        for r in batch.reactionAdds { try store.upsertReaction(r) }
        for rid in batch.reactionRemoves { try store.removeReaction(id: rid) }
        for a in batch.attachmentAdds { try store.ingest(a) }
        return ImportStats(threads: batch.threads.count, contacts: batch.contacts.count,
                           messages: batch.messages.count, newlyIngested: newly)
    }
}
