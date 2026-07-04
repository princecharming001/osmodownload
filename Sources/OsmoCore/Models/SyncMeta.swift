import Foundation
import CryptoKit

/// The sync-ready metadata carried by **every** persisted record (the load-bearing
/// P0 decision — see the plan). Building these in from row one makes the future
/// P2 E2EE cloud sync a drop-in instead of a data migration:
///
/// - `id`            UUID primary key. For platform-sourced rows it is *derived*
///                   from the platform's own stable GUID (`DeterministicID`), so
///                   the same real message resolves to the same UUID on every
///                   device that reads it — clean cross-device dedup.
/// - `updatedAt`     Last-write-wins clock for conflict resolution.
/// - `deviceSeq`     Per-device monotonic sequence number. Ties-break LWW when
///                   two devices share a wall-clock instant, and lets the sync
///                   engine ship an ordered oplog without trusting wall clocks.
/// - `deletedAt`     Soft-delete tombstone (never hard-DELETE — a hard delete
///                   can't propagate through an append-only sync log).
public struct SyncMeta: Codable, Equatable, Sendable {
    public var id: UUID
    public var updatedAt: Date
    public var deviceSeq: Int64
    public var deletedAt: Date?

    public init(id: UUID, updatedAt: Date, deviceSeq: Int64, deletedAt: Date? = nil) {
        self.id = id
        self.updatedAt = updatedAt
        self.deviceSeq = deviceSeq
        self.deletedAt = deletedAt
    }

    public var isDeleted: Bool { deletedAt != nil }
}

/// A record that carries `SyncMeta`. Column names are fixed so the store's
/// migrations and the future sync oplog can rely on them across every table.
public protocol SyncableRecord {
    var sync: SyncMeta { get set }

    /// Carry forward store-owned "enrichment" fields when a platform reader
    /// re-ingests a row it doesn't own. Default: no enrichment. Overridden by
    /// `OsmoContact` to keep its identity-graph `personID` across re-imports (the
    /// reader always produces `personID == nil`, so without this a re-ingest would
    /// clobber the link).
    func preservingEnrichment(from existing: Self) -> Self
}

public extension SyncableRecord {
    func preservingEnrichment(from existing: Self) -> Self { self }
}

/// Deterministic UUID v5 (RFC 4122, SHA-1) derivation. Used to mint stable IDs
/// from a platform's own durable identifier (e.g. iMessage `message.guid`, Gmail
/// RFC822 Message-ID) so re-ingesting the same thread — or ingesting it on a
/// second Mac — never duplicates rows and never needs a lookup table.
public enum DeterministicID {
    /// A fixed namespace UUID for Osmo (generated once, never change it — changing
    /// it re-mints every derived id and breaks dedup/sync).
    public static let namespace = UUID(uuidString: "6F9619FF-8B86-4EC5-0000-05C0FE0517A5")!

    /// UUID v5 of `name` within `namespace`.
    public static func v5(namespace: UUID = DeterministicID.namespace, name: String) -> UUID {
        var hasher = Insecure.SHA1()
        withUnsafeBytes(of: namespace.uuid) { hasher.update(bufferPointer: $0) }
        hasher.update(data: Data(name.utf8))
        var bytes = Array(hasher.finalize().prefix(16))
        // Set version (5) and RFC 4122 variant bits.
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let t = (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                 bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])
        return UUID(uuid: t)
    }

    /// Stable id for a platform-sourced entity, e.g. `for(.imessage, "message", guid)`.
    public static func forPlatform(_ platform: Platform, kind: String, key: String) -> UUID {
        v5(name: "\(platform.rawValue):\(kind):\(key)")
    }
}
