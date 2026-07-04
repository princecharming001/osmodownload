import Foundation
import GRDB

extension OsmoStore {
    /// Tables that sync (not `device`, not the FTS shadow). Ordered so that within
    /// a batch, referenced rows apply before referencing rows (FK-safe).
    static let syncTables: [String] = ["contact", "person", "thread", "project",
                                       "relationship_memory", "message"]
    private static func fkRank(_ table: String) -> Int {
        switch table {
        case "contact", "person": return 0
        case "thread", "project", "relationship_memory": return 1
        case "message": return 2
        default: return 3
        }
    }

    /// Local rows changed since a device-sequence high-water mark, as encryptable
    /// `SyncChange`s. `deviceSeq` is a single global counter, so one threshold
    /// covers every table.
    public func exportChanges(sinceDeviceSeq: Int64) throws -> [SyncChange] {
        try dbQueue.read { db in
            var out: [SyncChange] = []
            for table in Self.syncTables {
                let rows = try Row.fetchAll(db, sql:
                    "SELECT * FROM \(table) WHERE deviceSeq > ? ORDER BY deviceSeq",
                    arguments: [sinceDeviceSeq])
                for row in rows {
                    var cols: [String: SyncScalar] = [:]
                    for (name, value) in row { cols[name] = Self.scalar(value) }
                    let updatedAt = (row["updatedAt"] as Date?)?.timeIntervalSince1970 ?? 0
                    out.append(SyncChange(deviceID: deviceID, table: table,
                                          id: Self.idString(cols["id"]),
                                          updatedAt: updatedAt, columns: cols))
                }
            }
            return out.sorted { $0.updatedAt < $1.updatedAt }
        }
    }

    /// The highest local device sequence — the push high-water mark.
    public func currentDeviceSeq() throws -> Int64 {
        try dbQueue.read { db in try Int64.fetchOne(db, sql: "SELECT seq FROM device LIMIT 1") ?? 0 }
    }

    /// Apply remote changes with last-writer-wins (by `updatedAt`). Skips our own
    /// ops, keeps the local row when it's newer, and defers FK checks so a batch
    /// can arrive in any order. Returns how many rows were written.
    @discardableResult
    public func applyChanges(_ changes: [SyncChange]) throws -> Int {
        let incoming = changes
            .filter { $0.deviceID != deviceID }
            .sorted { Self.fkRank($0.table) < Self.fkRank($1.table) }
        guard !incoming.isEmpty else { return 0 }

        return try dbQueue.write { db in
            try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
            var applied = 0
            for change in incoming {
                guard Self.syncTables.contains(change.table) else { continue }
                let idValue = Self.dbValue(change.columns["id"])
                if let existing = try Row.fetchOne(db, sql:
                    "SELECT updatedAt FROM \(change.table) WHERE id = ?", arguments: [idValue]),
                   let localDate = existing["updatedAt"] as Date?,
                   change.updatedAt <= localDate.timeIntervalSince1970 {
                    continue   // local is newer or equal → keep it
                }
                let cols = change.columns.keys.sorted()
                let colList = cols.map { "\"\($0)\"" }.joined(separator: ",")
                let placeholders = cols.map { _ in "?" }.joined(separator: ",")
                let args = StatementArguments(cols.map { Self.dbValue(change.columns[$0]) })
                try db.execute(sql:
                    "INSERT OR REPLACE INTO \(change.table) (\(colList)) VALUES (\(placeholders))",
                    arguments: args)
                applied += 1
            }
            return applied
        }
    }

    // MARK: Scalar bridging

    static func scalar(_ v: DatabaseValue) -> SyncScalar {
        switch v.storage {
        case .null: return .null
        case .int64(let i): return .int(i)
        case .double(let d): return .double(d)
        case .string(let s): return .text(s)
        case .blob(let b): return .blob(b)
        }
    }

    static func dbValue(_ s: SyncScalar?) -> DatabaseValue {
        switch s {
        case .text(let x)?: return x.databaseValue
        case .int(let x)?: return x.databaseValue
        case .double(let x)?: return x.databaseValue
        case .blob(let x)?: return x.databaseValue
        case .null?, nil: return .null
        }
    }

    static func idString(_ s: SyncScalar?) -> String {
        switch s {
        case .text(let x)?: return x
        case .blob(let b)?: return b.base64EncodedString()
        default: return ""
        }
    }
}
