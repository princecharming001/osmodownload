import Foundation
import GRDB

/// One message as it sits in Apple's `chat.db`, before normalization. Field
/// choices reflect the verified July-2026 schema facts: `guid` is the stable
/// cross-device id; timestamps are Cocoa-nanosecond; `chat_identifier` is used
/// as the thread key (NOT the service-prefixed `chat.guid`, which flipped from
/// `iMessage;-;` to `any;-;` on Tahoe and breaks tools that key on the prefix).
public struct RawIMessage: Equatable, Sendable {
    public var guid: String
    public var text: String
    public var isFromMe: Bool
    public var dateRaw: Int64
    public var dateReadRaw: Int64
    /// Sender handle (phone/email); nil when from me or unknown.
    public var handle: String?
    public var chatGUID: String
    public var chatIdentifier: String?
    public var chatDisplayName: String?
    /// Apple `chat.style`: 43 = group, 45 = direct (1:1).
    public var chatStyle: Int
}

/// Read-only reader over a Messages `chat.db`. Opens the file **read-only** — Osmo
/// never mutates the user's Messages database. Requires Full Disk Access at
/// runtime to reach `~/Library/Messages/chat.db`; tests point it at a synthetic
/// fixture with the same schema.
public struct ChatDBReader: Sendable {
    private let dbQueue: DatabaseQueue

    public init(path: URL) throws {
        var config = Configuration()
        config.readonly = true
        self.dbQueue = try DatabaseQueue(path: path.path, configuration: config)
    }

    /// True iff the app can ACTUALLY read chat.db right now — opens it and runs a
    /// trivial query. This is the real Full-Disk-Access test: TCC denies the read
    /// even though the file is world-readable at the POSIX layer, so a plain
    /// `isReadableFile` check reports a false positive.
    public static func canRead(path: URL) -> Bool {
        guard let reader = try? ChatDBReader(path: path) else { return false }
        return (try? reader.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT 1 FROM message LIMIT 1")
        }) != nil
    }

    /// All text messages across all chats, oldest first. Messages whose body
    /// lives only in the `attributedBody` typedstream blob (rich content) are
    /// skipped for now — the plain-`text` column covers the vast majority and is
    /// enough for the P0 gate; attributedBody parsing is a follow-up.
    public func readAll() throws -> [RawIMessage] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: Self.query).map { row in
                RawIMessage(
                    guid: row["guid"],
                    text: row["text"],
                    isFromMe: (row["is_from_me"] as Int64) != 0,
                    dateRaw: row["date"],
                    dateReadRaw: row["date_read"] ?? 0,
                    handle: row["handle"],
                    chatGUID: row["chat_guid"],
                    chatIdentifier: row["chat_identifier"],
                    chatDisplayName: row["chat_display_name"],
                    chatStyle: Int(row["chat_style"] as Int64? ?? 45))
            }
        }
    }

    /// Incremental read for the realtime poll loop: only messages with
    /// `ROWID > rowID` (ROWID is monotonic in chat.db — cheaper and safer than
    /// date math), plus the new high-water mark. Each call runs in a fresh read
    /// transaction, so WAL content committed by Messages since the last poll is
    /// visible without reopening the file.
    public func readSince(rowID: Int64) throws -> (rows: [RawIMessage], maxRowID: Int64) {
        try dbQueue.read { db in
            var maxRowID = rowID
            let rows = try Row.fetchAll(db, sql: Self.sinceQuery, arguments: [rowID]).map { row in
                maxRowID = Swift.max(maxRowID, row["rowid"] as Int64)
                return RawIMessage(
                    guid: row["guid"],
                    text: row["text"],
                    isFromMe: (row["is_from_me"] as Int64) != 0,
                    dateRaw: row["date"],
                    dateReadRaw: row["date_read"] ?? 0,
                    handle: row["handle"],
                    chatGUID: row["chat_guid"],
                    chatIdentifier: row["chat_identifier"],
                    chatDisplayName: row["chat_display_name"],
                    chatStyle: Int(row["chat_style"] as Int64? ?? 45))
            }
            return (rows, maxRowID)
        }
    }

    /// Current max message ROWID — the starting watermark so the realtime loop
    /// doesn't re-deliver history the initial import already ingested.
    public func currentMaxRowID() throws -> Int64 {
        try dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(ROWID), 0) FROM message") ?? 0
        }
    }

    static let baseSelect = """
        SELECT
            m.ROWID             AS rowid,
            m.guid              AS guid,
            m.text              AS text,
            m.is_from_me        AS is_from_me,
            m.date              AS date,
            m.date_read         AS date_read,
            h.id                AS handle,
            c.guid              AS chat_guid,
            c.chat_identifier   AS chat_identifier,
            c.display_name      AS chat_display_name,
            c.style             AS chat_style
        FROM message m
        JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        JOIN chat c                ON c.ROWID = cmj.chat_id
        LEFT JOIN handle h         ON h.ROWID = m.handle_id
        WHERE m.text IS NOT NULL AND m.text <> ''
        """

    static let query = baseSelect + " ORDER BY m.date ASC"
    static let sinceQuery = baseSelect + " AND m.ROWID > ? ORDER BY m.ROWID ASC"
}
