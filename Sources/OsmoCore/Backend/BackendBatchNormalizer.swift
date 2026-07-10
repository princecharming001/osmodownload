import Foundation

/// Wire rows → canonical batch. Pure and fixture-testable, same pattern as the
/// platform normalizers. UUIDs are minted HERE via the existing deterministic
/// derivations — the backend never speaks Osmo IDs, so the two sides can't
/// drift. Sync clocks are left at epoch; the store stamps them on ingest.
public enum BackendBatchNormalizer {

    /// Rows whose platform string the app doesn't know yet are skipped, not
    /// fatal — the backend may add platforms (e.g. Telegram) before the app.
    public struct Result: Sendable {
        public var batch: NormalizedBatch
        public var skippedUnknownPlatform: Int
        /// Malformed rows dropped defensively (e.g. a contact with an empty
        /// handle — it can't key an identity and would only pollute the store).
        public var skippedInvalid: Int
    }

    public static func normalize(_ wire: WireBatch) -> Result {
        var skipped = 0
        var invalid = 0
        let epoch = Date(timeIntervalSince1970: 0)

        var contacts: [OsmoContact] = []
        for w in wire.contacts {
            guard let platform = Platform(rawValue: w.platform) else { skipped += 1; continue }
            guard !w.handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                invalid += 1; continue
            }
            contacts.append(OsmoContact(
                id: OsmoContact.makeID(platform: platform, handle: w.handle),
                updatedAt: epoch, deviceSeq: 0,
                platform: platform, handle: w.handle,
                displayName: w.displayName, isMe: w.isMe))
        }

        var threads: [OsmoThread] = []
        for w in wire.threads {
            guard let platform = Platform(rawValue: w.platform) else { skipped += 1; continue }
            threads.append(OsmoThread(
                id: OsmoThread.makeID(platform: platform, platformThreadID: w.platformThreadID),
                updatedAt: epoch, deviceSeq: 0,
                platform: platform, platformThreadID: w.platformThreadID,
                title: w.title, isGroup: w.isGroup, lastMessageAt: w.lastMessageAt,
                automatedHint: w.automatedHint ?? false, providerThreadID: w.providerThreadID))
        }

        var messages: [OsmoMessage] = []
        var reactionAdds: [MessageReaction] = []
        var attachmentAdds: [OsmoAttachment] = []
        for w in wire.messages {
            guard let platform = Platform(rawValue: w.platform) else { skipped += 1; continue }
            let messageID = OsmoMessage.makeID(platform: platform, platformMessageID: w.platformMessageID)
            messages.append(OsmoMessage(
                id: messageID,
                updatedAt: epoch, deviceSeq: 0,
                platform: platform, platformMessageID: w.platformMessageID,
                threadID: OsmoThread.makeID(platform: platform, platformThreadID: w.platformThreadID),
                // An empty sender handle can't reference a contact row (empty-
                // handle contacts are skipped above) — minting an id for it
                // would FK-fail the whole message on ingest. Treat it as nil,
                // the same as a wire message with no sender at all.
                senderContactID: w.senderHandle
                    .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                    .map { OsmoContact.makeID(platform: platform, handle: $0) },
                isFromMe: w.isFromMe, text: w.text,
                sentAt: w.sentAt, readAt: w.readAt,
                inReplyToMessageID: w.replyToMessageID.map {
                    OsmoMessage.makeID(platform: platform, platformMessageID: $0)
                }))
            // Provider emoji reactions fold onto their message exactly like
            // iMessage tapbacks — deterministic id over (target, reactor, emoji)
            // so re-pulls and overlapping pages dedup to one row.
            for r in w.reactions ?? [] {
                let reactor = r.isFromMe ? "me" : (r.senderHandle ?? "?")
                reactionAdds.append(MessageReaction(
                    id: MessageReaction.makeID(targetGuid: "\(platform.rawValue):\(w.platformMessageID)",
                                               reactorKey: reactor, type: "emoji:\(r.emoji)"),
                    targetMessageID: messageID,
                    reactorContactID: r.isFromMe ? nil : r.senderHandle.map {
                        OsmoContact.makeID(platform: platform, handle: $0)
                    },
                    reactionType: "emoji", emoji: r.emoji,
                    isFromMe: r.isFromMe, reactedAt: w.sentAt))
            }
            // Media/file/link attachments — a lazily-fetched remote ref for
            // everything except `link` (a shared post/reel has no bytes).
            for a in w.attachments ?? [] {
                let kind = AttachmentKind(rawValue: a.kind) ?? .from(mimeType: a.mimeType)
                attachmentAdds.append(OsmoAttachment(
                    id: OsmoAttachment.makeID(platform: platform, platformMessageID: w.platformMessageID,
                                              attachmentRef: a.id),
                    updatedAt: epoch, deviceSeq: 0,
                    messageID: messageID, kind: kind, mimeType: a.mimeType, filename: a.filename,
                    sizeBytes: a.sizeBytes, width: a.width, height: a.height,
                    remoteRef: a.remoteRef, linkURL: a.url, title: a.title))
            }
        }

        return Result(batch: NormalizedBatch(contacts: contacts, threads: threads, messages: messages,
                                             reactionAdds: reactionAdds, attachmentAdds: attachmentAdds),
                      skippedUnknownPlatform: skipped, skippedInvalid: invalid)
    }
}
