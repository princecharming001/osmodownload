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

    static let query = """
        SELECT
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
        ORDER BY m.date ASC
        """
}
