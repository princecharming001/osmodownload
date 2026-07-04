import Foundation
import GRDB

/// A platform-specific handle for a person — one row per (platform, handle).
/// The cross-platform *person* lives in the identity graph (P3); `personID`
/// links this handle to that merged person once resolved (nil until then).
/// Flat columns (not a nested `SyncMeta`) so the sync fields are real, indexable
/// DB columns; the `sync` accessor satisfies `SyncableRecord`.
public struct OsmoContact: Codable, Equatable, Sendable, Identifiable, SyncableRecord,
                           FetchableRecord, PersistableRecord {
    public var id: UUID
    public var updatedAt: Date
    public var deviceSeq: Int64
    public var deletedAt: Date?

    public var platform: Platform
    /// The platform-native identifier: E.164 phone, email, @handle, Slack user id.
    public var handle: String
    public var displayName: String?
    public var avatarData: Data?
    /// Identity-graph person this handle resolves to (P3); nil until merged.
    public var personID: UUID?
    /// True for the account owner's own handle on this platform.
    public var isMe: Bool

    public static let databaseTableName = "contact"

    public var sync: SyncMeta {
        get { SyncMeta(id: id, updatedAt: updatedAt, deviceSeq: deviceSeq, deletedAt: deletedAt) }
        set { id = newValue.id; updatedAt = newValue.updatedAt
              deviceSeq = newValue.deviceSeq; deletedAt = newValue.deletedAt }
    }

    public init(id: UUID, updatedAt: Date, deviceSeq: Int64, deletedAt: Date? = nil,
                platform: Platform, handle: String, displayName: String? = nil,
                avatarData: Data? = nil, personID: UUID? = nil, isMe: Bool = false) {
        self.id = id
        self.updatedAt = updatedAt
        self.deviceSeq = deviceSeq
        self.deletedAt = deletedAt
        self.platform = platform
        self.handle = handle
        self.displayName = displayName
        self.avatarData = avatarData
        self.personID = personID
        self.isMe = isMe
    }

    /// A handle's id is derived from (platform, handle) so re-ingest / a second
    /// Mac resolves to the same row.
    public static func makeID(platform: Platform, handle: String) -> UUID {
        DeterministicID.forPlatform(platform, kind: "contact", key: handle)
    }
}
