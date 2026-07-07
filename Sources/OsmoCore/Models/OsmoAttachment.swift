import Foundation
import GRDB

/// The coarse media kind — enough to pick a bubble treatment (inline image,
/// video thumb, audio/file chip, or a bare link row for a shared post/reel
/// with no fetchable bytes). Mirrors the web wire contract's `AttachmentKind`.
public enum AttachmentKind: String, Codable, Sendable, CaseIterable {
    case image, video, audio, file, link
}

/// A media attachment on a message. Full bytes are fetched lazily (via
/// `BackendClient.fetchMedia` + `MediaStore`) and cached on disk — `localPath`
/// records where; `thumbnailData` is a small inline preview (≤300KB) for an
/// instant render before the fetch completes. Both are store-owned: a re-ingest
/// (a re-pull, a resync) must never wipe a cache that's already been filled.
public struct OsmoAttachment: Codable, Equatable, Sendable, Identifiable, SyncableRecord,
                              FetchableRecord, PersistableRecord {
    public var id: UUID
    public var updatedAt: Date
    public var deviceSeq: Int64
    public var deletedAt: Date?

    public var messageID: UUID
    public var kind: AttachmentKind
    public var mimeType: String?
    public var filename: String?
    public var sizeBytes: Int64?
    public var width: Int?
    public var height: Int?
    /// Opaque provider ref used to refetch bytes through the media pipeline
    /// (Gmail attachmentId, Slack url_private, Unipile attachment id, or an
    /// iMessage local file path). nil for `link` kind, which has no bytes.
    public var remoteRef: String?
    /// Destination URL for `link` kind (a shared post/reel) — no bytes exist.
    public var linkURL: String?
    public var title: String?
    /// Once fetched, the on-disk cache path. Store-owned — see `preservingEnrichment`.
    public var localPath: String?
    /// A small inline preview, store-owned same as `localPath`.
    public var thumbnailData: Data?

    public static let databaseTableName = "message_attachment"

    public var sync: SyncMeta {
        get { SyncMeta(id: id, updatedAt: updatedAt, deviceSeq: deviceSeq, deletedAt: deletedAt) }
        set { id = newValue.id; updatedAt = newValue.updatedAt
              deviceSeq = newValue.deviceSeq; deletedAt = newValue.deletedAt }
    }

    public init(id: UUID, updatedAt: Date, deviceSeq: Int64, deletedAt: Date? = nil,
                messageID: UUID, kind: AttachmentKind, mimeType: String? = nil,
                filename: String? = nil, sizeBytes: Int64? = nil, width: Int? = nil,
                height: Int? = nil, remoteRef: String? = nil, linkURL: String? = nil,
                title: String? = nil, localPath: String? = nil, thumbnailData: Data? = nil) {
        self.id = id; self.updatedAt = updatedAt; self.deviceSeq = deviceSeq; self.deletedAt = deletedAt
        self.messageID = messageID; self.kind = kind; self.mimeType = mimeType
        self.filename = filename; self.sizeBytes = sizeBytes; self.width = width; self.height = height
        self.remoteRef = remoteRef; self.linkURL = linkURL; self.title = title
        self.localPath = localPath; self.thumbnailData = thumbnailData
    }

    /// Deterministic per-(message, attachment) id — a re-pull of the same
    /// message resolves to the same row instead of duplicating.
    public static func makeID(platform: Platform, platformMessageID: String, attachmentRef: String) -> UUID {
        DeterministicID.forPlatform(platform, kind: "attachment", key: "\(platformMessageID):\(attachmentRef)")
    }

    /// Never let a re-ingest (a resync, a re-pull) wipe media already cached
    /// on this device — the reader always produces nil for both.
    public func preservingEnrichment(from stored: OsmoAttachment) -> OsmoAttachment {
        var merged = self
        merged.localPath = localPath ?? stored.localPath
        merged.thumbnailData = thumbnailData ?? stored.thumbnailData
        return merged
    }
}

public extension AttachmentKind {
    /// Classify from a mime type alone — every Swift-side reader (iMessage,
    /// the backend wire) has at most a mime type, never a provider type-hint
    /// string the way the web-side readers sometimes do.
    static func from(mimeType: String?) -> AttachmentKind {
        guard let mimeType else { return .file }
        if mimeType.hasPrefix("image/") { return .image }
        if mimeType.hasPrefix("video/") { return .video }
        if mimeType.hasPrefix("audio/") { return .audio }
        return .file
    }
}
