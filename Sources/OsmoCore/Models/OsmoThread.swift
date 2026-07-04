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

    public static let databaseTableName = "thread"

    public var sync: SyncMeta {
        get { SyncMeta(id: id, updatedAt: updatedAt, deviceSeq: deviceSeq, deletedAt: deletedAt) }
        set { id = newValue.id; updatedAt = newValue.updatedAt
              deviceSeq = newValue.deviceSeq; deletedAt = newValue.deletedAt }
    }

    public init(id: UUID, updatedAt: Date, deviceSeq: Int64, deletedAt: Date? = nil,
                platform: Platform, platformThreadID: String, title: String? = nil,
                isGroup: Bool = false, lastMessageAt: Date? = nil) {
        self.id = id
        self.updatedAt = updatedAt
        self.deviceSeq = deviceSeq
        self.deletedAt = deletedAt
        self.platform = platform
        self.platformThreadID = platformThreadID
        self.title = title
        self.isGroup = isGroup
        self.lastMessageAt = lastMessageAt
    }

    public static func makeID(platform: Platform, platformThreadID: String) -> UUID {
        DeterministicID.forPlatform(platform, kind: "thread", key: platformThreadID)
    }
}
