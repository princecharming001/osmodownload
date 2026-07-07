import Foundation
import GRDB

/// A conversation on one platform (1:1 or group). `platformThreadID` is the
/// platform's own stable thread identifier (iMessage chat GUID, Gmail thread id,
/// Slack channel id); the Osmo `id` is derived from it for cross-device dedup.
public struct OsmoThread: Codable, Equatable, Sendable, Identifiable, SyncableRecord,
                          FetchableRecord, PersistableRecord {
    public var id: UUID
    public var updatedAt: Date
    public var deviceSeq: Int64
    public var deletedAt: Date?

    public var platform: Platform
    public var platformThreadID: String
    public var title: String?
    public var isGroup: Bool
    public var lastMessageAt: Date?
    /// Server-side signal that this thread looks automated (Gmail List-Unsubscribe/
    /// Precedence/sender-shape) — feeds the human-thread classifier. Defaulted so
    /// pre-existing rows and fixtures decode unchanged.
    public var automatedHint: Bool = false
    /// The provider's OWN thread/conversation id (Unipile's chat id is internal
    /// and can't be turned into a working deep link). nil when unknown.
    public var providerThreadID: String? = nil

    public static let databaseTableName = "thread"

    public var sync: SyncMeta {
        get { SyncMeta(id: id, updatedAt: updatedAt, deviceSeq: deviceSeq, deletedAt: deletedAt) }
        set { id = newValue.id; updatedAt = newValue.updatedAt
              deviceSeq = newValue.deviceSeq; deletedAt = newValue.deletedAt }
    }

    public init(id: UUID, updatedAt: Date, deviceSeq: Int64, deletedAt: Date? = nil,
                platform: Platform, platformThreadID: String, title: String? = nil,
                isGroup: Bool = false, lastMessageAt: Date? = nil,
                automatedHint: Bool = false, providerThreadID: String? = nil) {
        self.id = id
        self.updatedAt = updatedAt
        self.deviceSeq = deviceSeq
        self.deletedAt = deletedAt
        self.platform = platform
        self.platformThreadID = platformThreadID
        self.title = title
        self.isGroup = isGroup
        self.lastMessageAt = lastMessageAt
        self.automatedHint = automatedHint
        self.providerThreadID = providerThreadID
    }

    public static func makeID(platform: Platform, platformThreadID: String) -> UUID {
        DeterministicID.forPlatform(platform, kind: "thread", key: platformThreadID)
    }

    /// Two re-ingest hazards, fixed the same way OsmoContact protects personID:
    /// (1) a webhook/mid-page bundle carries no chat index, so its
    /// `providerThreadID` is nil — that must never erase a value a fuller pull
    /// already resolved; (2) providers page newest-first, so an OUT-OF-ORDER
    /// later page can carry an OLDER `lastMessageAt` than what's stored — a
    /// blind overwrite would regress the inbox's sort order mid-backfill.
    public func preservingEnrichment(from existing: OsmoThread) -> OsmoThread {
        var t = self
        if t.providerThreadID == nil { t.providerThreadID = existing.providerThreadID }
        if let existingAt = existing.lastMessageAt, let incomingAt = t.lastMessageAt, incomingAt < existingAt {
            t.lastMessageAt = existingAt
        }
        return t
    }
}
