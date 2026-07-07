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
    /// chat.db ROWID — the monotonic import watermark. Defaulted (and placed last)
    /// so existing constructions in tests/fixtures keep compiling unchanged.
    public var rowID: Int64 = 0
    /// `associated_message_type`: 0 = a normal message; 2000–2006 add a tapback,
    /// 3000–3006 remove one.
    public var associatedType: Int = 0
    /// `associated_message_guid` of the reacted-to message (often prefixed
    /// `p:0/GUID` or `bp:GUID` — parse with `bareGuid`).
    public var associatedGuid: String? = nil
    /// `associated_message_emoji` for an arbitrary-emoji tapback (type 2006/3006).
    public var associatedEmoji: String? = nil
    /// `thread_originator_guid`: the guid of the message this one replies to.
    public var threadOriginatorGuid: String? = nil
    /// This message's attachments, read via a separate batched join (see
    /// `ChatDBReader.attachRows`) so a multi-attachment message doesn't
    /// multiply the main message row. Defaulted (and placed last) so existing
    /// constructions keep compiling unchanged.
    public var attachments: [RawAttachment] = []
}

/// One row of Apple's `attachment` table, joined via `message_attachment_join`.
/// `filename` is the on-disk path chat.db recorded at import time (often
/// `~/Library/Messages/Attachments/...`) — may point at a file iCloud has
/// since evicted; `transferName` is the original filename for display.
public struct RawAttachment: Equatable, Sendable {
    public var guid: String
    public var filename: String?
    public var mimeType: String?
    public var transferName: String?
    public var totalBytes: Int64
}

/// Read-only reader over a Messages `chat.db`. Opens the file **read-only** — Osmo
/// never mutates the user's Messages database. Requires Full Disk Access at
/// runtime to reach `~/Library/Messages/chat.db`; tests point it at a synthetic
/// fixture with the same schema.
public struct ChatDBReader: Sendable {
    private let dbQueue: DatabaseQueue
    /// SELECT built from the columns THIS chat.db actually has — reaction/reply
    /// columns arrived in different macOS versions, and referencing one that's
    /// missing would fail the whole import. Missing columns are selected as NULL
    /// (mapped to defaults), so iMessage sync degrades gracefully on old builds.
    private let baseSelect: String
    /// Whether this chat.db has the attachment tables at all — absent on a
    /// synthetic/very old fixture; attachment reading degrades to "none" rather
    /// than failing the whole import.
    private let hasAttachmentTables: Bool

    public init(path: URL) throws {
        var config = Configuration()
        config.readonly = true
        let queue = try DatabaseQueue(path: path.path, configuration: config)
        self.dbQueue = queue
        let cols = Set((try? queue.read { db in try db.columns(in: "message").map(\.name) }) ?? [])
        self.baseSelect = Self.buildBaseSelect(available: cols)
        self.hasAttachmentTables = (try? queue.read { db in
            try db.tableExists("attachment") && db.tableExists("message_attachment_join")
        }) ?? false
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

    /// Total messages in chat.db — the denominator for import progress.
    public func totalMessageCount() throws -> Int {
        try dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message") ?? 0 }
    }

    /// All text messages across all chats, oldest first. Messages whose body
    /// lives only in the `attributedBody` typedstream blob (rich content) are
    /// skipped for now — the plain-`text` column covers the vast majority and is
    /// enough for the P0 gate; attributedBody parsing is a follow-up.
    public func readAll() throws -> [RawIMessage] {
        try dbQueue.read { db in
            var rows = try Row.fetchAll(db, sql: query).map(Self.rawMessage(from:))
            try attach(&rows, in: db)
            return rows
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
            var rows = try Row.fetchAll(db, sql: sinceQuery, arguments: [rowID]).map { row -> RawIMessage in
                let raw = Self.rawMessage(from: row)
                maxRowID = Swift.max(maxRowID, raw.rowID)
                return raw
            }
            try attach(&rows, in: db)
            return (rows, maxRowID)
        }
    }

    /// Attach each message's attachments via ONE separate batched join (never
    /// folded into the main per-page SELECT, which would multiply a message row
    /// once per attachment). No-ops on a chat.db without the attachment tables.
    private func attach(_ rows: inout [RawIMessage], in db: Database) throws {
        guard hasAttachmentTables, !rows.isEmpty else { return }
        let ids = rows.map(\.rowID)
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let sql = """
            SELECT maj.message_id AS message_id, a.guid AS guid, a.filename AS filename,
                   a.mime_type AS mime_type, a.transfer_name AS transfer_name,
                   a.total_bytes AS total_bytes
            FROM message_attachment_join maj
            JOIN attachment a ON a.ROWID = maj.attachment_id
            WHERE maj.message_id IN (\(placeholders))
            """
        let attRows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(ids))
        var byMessage: [Int64: [RawAttachment]] = [:]
        for r in attRows {
            let messageID: Int64 = r["message_id"]
            byMessage[messageID, default: []].append(RawAttachment(
                guid: r["guid"], filename: r["filename"], mimeType: r["mime_type"],
                transferName: r["transfer_name"], totalBytes: r["total_bytes"] ?? 0))
        }
        guard !byMessage.isEmpty else { return }
        for i in rows.indices {
            if let atts = byMessage[rows[i].rowID] { rows[i].attachments = atts }
        }
    }

    /// Current max message ROWID — the starting watermark so the realtime loop
    /// doesn't re-deliver history the initial import already ingested.
    public func currentMaxRowID() throws -> Int64 {
        try dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(ROWID), 0) FROM message") ?? 0
        }
    }

    /// `m.<name> AS alias` when the column exists, else `NULL AS alias`.
    private static func col(_ name: String, as alias: String, _ available: Set<String>) -> String {
        available.contains(name) ? "m.\(name) AS \(alias)" : "NULL AS \(alias)"
    }

    static func buildBaseSelect(available: Set<String>) -> String {
        let hasAssoc = available.contains("associated_message_type")
        // Include reaction rows (empty text) only when the column exists.
        let reactionClause = hasAssoc ? " OR m.associated_message_type <> 0" : ""
        // Attachment-only messages (a photo/video with no caption) have empty
        // text too — without this, they never reach the attachment join below
        // at all. Column-availability-gated exactly like the reaction clause.
        let attachmentClause = available.contains("cache_has_attachments")
            ? " OR m.cache_has_attachments = 1" : ""
        return """
        SELECT
            m.ROWID         AS rowid,
            m.guid          AS guid,
            m.text          AS text,
            m.is_from_me    AS is_from_me,
            m.date          AS date,
            m.date_read     AS date_read,
            \(col("associated_message_type", as: "assoc_type", available)),
            \(col("associated_message_guid", as: "assoc_guid", available)),
            \(col("associated_message_emoji", as: "assoc_emoji", available)),
            \(col("thread_originator_guid", as: "reply_guid", available)),
            h.id            AS handle,
            c.guid          AS chat_guid,
            c.chat_identifier AS chat_identifier,
            c.display_name  AS chat_display_name,
            c.style         AS chat_style
        FROM message m
        JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        JOIN chat c                ON c.ROWID = cmj.chat_id
        LEFT JOIN handle h         ON h.ROWID = m.handle_id
        WHERE ((m.text IS NOT NULL AND m.text <> '')\(reactionClause)\(attachmentClause))
        """
    }

    private var query: String { baseSelect + " ORDER BY m.date ASC" }
    private var sinceQuery: String { baseSelect + " AND m.ROWID > ? ORDER BY m.ROWID ASC" }

    /// Map one result row (from `baseSelect`) into a RawIMessage. Shared by
    /// `readAll` + `readSince` so the column list can't drift between them. Older
    /// macOS chat.db builds may lack the reaction/reply columns; `?? ` defaults
    /// keep the read working on any version.
    static func rawMessage(from row: Row) -> RawIMessage {
        RawIMessage(
            guid: row["guid"],
            text: row["text"] ?? "",
            isFromMe: (row["is_from_me"] as Int64) != 0,
            dateRaw: row["date"],
            dateReadRaw: row["date_read"] ?? 0,
            handle: row["handle"],
            chatGUID: row["chat_guid"],
            chatIdentifier: row["chat_identifier"],
            chatDisplayName: row["chat_display_name"],
            chatStyle: Int(row["chat_style"] as Int64? ?? 45),
            rowID: (row["rowid"] as Int64?) ?? 0,
            associatedType: Int(row["assoc_type"] as Int64? ?? 0),
            associatedGuid: row["assoc_guid"],
            associatedEmoji: row["assoc_emoji"],
            threadOriginatorGuid: row["reply_guid"])
    }

    /// Strip Apple's `p:0/`, `bp:` (etc.) prefixes off an associated-message /
    /// reply guid to get the bare message guid the target row uses.
    public static func bareGuid(_ s: String) -> String {
        String(s.split(separator: "/").last ?? Substring(s))
    }
}
