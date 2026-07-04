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
    }

    public static func normalize(_ wire: WireBatch) -> Result {
        var skipped = 0
        let epoch = Date(timeIntervalSince1970: 0)

        var contacts: [OsmoContact] = []
        for w in wire.contacts {
            guard let platform = Platform(rawValue: w.platform) else { skipped += 1; continue }
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
                title: w.title, isGroup: w.isGroup, lastMessageAt: w.lastMessageAt))
        }

        var messages: [OsmoMessage] = []
        for w in wire.messages {
            guard let platform = Platform(rawValue: w.platform) else { skipped += 1; continue }
            messages.append(OsmoMessage(
                id: OsmoMessage.makeID(platform: platform, platformMessageID: w.platformMessageID),
                updatedAt: epoch, deviceSeq: 0,
                platform: platform, platformMessageID: w.platformMessageID,
                threadID: OsmoThread.makeID(platform: platform, platformThreadID: w.platformThreadID),
                senderContactID: w.senderHandle.map { OsmoContact.makeID(platform: platform, handle: $0) },
                isFromMe: w.isFromMe, text: w.text,
                sentAt: w.sentAt, readAt: w.readAt))
        }

        return Result(batch: NormalizedBatch(contacts: contacts, threads: threads, messages: messages),
                      skippedUnknownPlatform: skipped)
    }
}
