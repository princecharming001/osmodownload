import Foundation
import GRDB

/// A single message in a thread — the atom of the unified inbox and the unit the
/// suggestion engine reasons over. `platformMessageID` is the platform's stable
/// GUID; the Osmo `id` is derived from it so re-ingest and a second Mac converge
/// on the same row. Body text is stored plaintext *inside the encrypted store*
/// (SQLCipher whole-DB) and mirrored into an FTS5 index for unified search.
public struct OsmoMessage: Codable, Equatable, Sendable, Identifiable, SyncableRecord,
                           FetchableRecord, PersistableRecord {
    public var id: UUID
    public var updatedAt: Date
    public var deviceSeq: Int64
    public var deletedAt: Date?

    public var platform: Platform
    public var platformMessageID: String
    public var threadID: UUID
    /// Sender handle (FK → contact.id); nil when unknown or when `isFromMe`.
    public var senderContactID: UUID?
    public var isFromMe: Bool
    public var text: String
    public var sentAt: Date
    /// Real read-receipt time where the platform exposes it (iMessage `date_read`).
    /// This is what upgrades texting-status from inference to fact.
    public var readAt: Date?
    /// The message this one is a reply to (iMessage `thread_originator_guid`),
    /// resolved to the target Osmo message id; nil for non-replies.
    public var inReplyToMessageID: UUID?

    public static let databaseTableName = "message"

    public var sync: SyncMeta {
        get { SyncMeta(id: id, updatedAt: updatedAt, deviceSeq: deviceSeq, deletedAt: deletedAt) }
        set { id = newValue.id; updatedAt = newValue.updatedAt
              deviceSeq = newValue.deviceSeq; deletedAt = newValue.deletedAt }
    }

    public init(id: UUID, updatedAt: Date, deviceSeq: Int64, deletedAt: Date? = nil,
                platform: Platform, platformMessageID: String, threadID: UUID,
                senderContactID: UUID? = nil, isFromMe: Bool, text: String,
                sentAt: Date, readAt: Date? = nil, inReplyToMessageID: UUID? = nil) {
        self.id = id
        self.updatedAt = updatedAt
        self.deviceSeq = deviceSeq
        self.deletedAt = deletedAt
        self.platform = platform
        self.platformMessageID = platformMessageID
        self.threadID = threadID
        self.senderContactID = senderContactID
        self.isFromMe = isFromMe
        self.text = text
        self.sentAt = sentAt
        self.readAt = readAt
        self.inReplyToMessageID = inReplyToMessageID
    }

    public static func makeID(platform: Platform, platformMessageID: String) -> UUID {
        DeterministicID.forPlatform(platform, kind: "message", key: platformMessageID)
    }
}
