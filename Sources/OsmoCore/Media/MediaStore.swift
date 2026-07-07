import Foundation

/// Local on-disk cache for fetched attachment media (photos/videos/audio/
/// files) — lazily populated on first render, never evicted (v1; total size is
/// surfaced in Settings → Privacy copy so the user isn't surprised by it).
/// Thumbnails stay inline in the DB (`OsmoAttachment.thumbnailData`); this is
/// only for the full-size bytes.
public struct MediaStore: Sendable {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public static func appSupport() -> MediaStore {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return MediaStore(directory: base.appendingPathComponent("Osmo/media", isDirectory: true))
    }

    private func path(id: UUID, ext: String) -> URL {
        directory.appendingPathComponent(ext.isEmpty ? id.uuidString : "\(id.uuidString).\(ext)")
    }

    /// The cached file's path if it already exists on disk — nil means "not
    /// fetched yet" (v1 never evicts, so nil always means genuinely unfetched).
    public func existingPath(id: UUID, ext: String) -> URL? {
        let url = path(id: id, ext: ext)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Write fetched bytes to the cache, returning the file's path.
    @discardableResult
    public func store(id: UUID, ext: String, data: Data) throws -> URL {
        let url = path(id: id, ext: ext)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Total bytes cached so far.
    public func totalSizeBytes() -> Int64 {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return items.reduce(Int64(0)) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }
}
