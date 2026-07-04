import Foundation
import GRDB

/// A real human — the merged identity that a person's handles across platforms
/// resolve to. `OsmoContact.personID` points here. Built by the identity graph:
/// deterministic joins on global identifiers (phone/email) auto-merge; ambiguous
/// name/avatar matches become review suggestions, never silent merges.
public struct Person: Codable, Equatable, Sendable, Identifiable, SyncableRecord,
                      FetchableRecord, PersistableRecord {
    public var id: UUID
    public var updatedAt: Date
    public var deviceSeq: Int64
    public var deletedAt: Date?

    public var displayName: String
    public var avatarData: Data?
    /// True once a human confirmed the merge (vs. an auto/deterministic merge).
    public var reviewed: Bool

    public static let databaseTableName = "person"

    public var sync: SyncMeta {
        get { SyncMeta(id: id, updatedAt: updatedAt, deviceSeq: deviceSeq, deletedAt: deletedAt) }
        set { id = newValue.id; updatedAt = newValue.updatedAt
              deviceSeq = newValue.deviceSeq; deletedAt = newValue.deletedAt }
    }

    public init(id: UUID = UUID(), updatedAt: Date = Date(timeIntervalSince1970: 0),
                deviceSeq: Int64 = 0, deletedAt: Date? = nil,
                displayName: String, avatarData: Data? = nil, reviewed: Bool = false) {
        self.id = id
        self.updatedAt = updatedAt
        self.deviceSeq = deviceSeq
        self.deletedAt = deletedAt
        self.displayName = displayName
        self.avatarData = avatarData
        self.reviewed = reviewed
    }
}
