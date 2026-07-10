import Foundation
import GRDB

// osmo-tool — maintenance CLI for the local Osmo store.
//
//   swift run osmo-tool purge-demo            # report what WOULD be deleted
//   swift run osmo-tool purge-demo --apply    # actually delete + vacuum
//
// Purges keyless/mock-mode content that leaked into a store that also holds
// real data: demo threads are deterministic (`platformThreadID` = "demo-…"),
// probe emits use known thread keys. Real platform ids (iMessage GUIDs, Gmail
// hex ids, Unipile ids) never match these patterns.
//
// Unlike the app's opener this NEVER deletes the database on a key mismatch —
// it fails loudly instead. Quit Osmo before running with --apply.

let supportDir = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Osmo", isDirectory: true)
let dbURL = supportDir.appendingPathComponent("osmo.db")
let keyURL = supportDir.appendingPathComponent(".dbkey")

let args = CommandLine.arguments.dropFirst()
guard let cmd = args.first, ["purge-demo", "inspect"].contains(cmd) else {
    print("usage: osmo-tool purge-demo [--apply] | inspect [name-fragment]"); exit(2)
}
let apply = args.contains("--apply")

guard let key = (try? String(contentsOf: keyURL, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
    print("✗ no .dbkey at \(keyURL.path)"); exit(1)
}
var config = Configuration()
config.prepareDatabase { db in try db.usePassphrase(key) }
let dbQueue: DatabaseQueue
do {
    dbQueue = try DatabaseQueue(path: dbURL.path, configuration: config)
    // Force a real read so a wrong key fails HERE, not mid-delete.
    _ = try dbQueue.read { try Int.fetchOne($0, sql: "select count(*) from thread") }
} catch {
    print("✗ cannot open store (wrong key or locked): \(error)"); exit(1)
}

if cmd == "inspect" {
    let frag = args.dropFirst().first ?? ""
    do {
        try dbQueue.read { db in
            let byPlatform = try Row.fetchAll(db, sql:
                "select platform, count(*) n from thread group by platform order by n desc")
            print("threads by platform:")
            for r in byPlatform { print("  \(r["platform"] as String? ?? "?"): \(r["n"] as Int? ?? 0)") }
            if !frag.isEmpty {
                let rows = try Row.fetchAll(db, sql: """
                    select t.platform, t.platformThreadID, t.title, c.name, c.handle
                    from thread t
                    left join message m on m.threadID = t.id
                    left join contact c on c.id = m.senderID
                    where c.name like ? or t.title like ?
                    group by t.id limit 20
                    """, arguments: ["%\(frag)%", "%\(frag)%"])
                print("\nmatches for '\(frag)':")
                for r in rows {
                    print("  [\(r["platform"] as String? ?? "?")] pid=\(r["platformThreadID"] as String? ?? "?") title=\(r["title"] as String? ?? "-") sender=\(r["name"] as String? ?? "-") <\(r["handle"] as String? ?? "-")>")
                }
            }
        }
    } catch { print("✗ inspect failed: \(error)"); exit(1) }
    exit(0)
}

// Mock-origin fingerprints. `demo-…` is the seeded dataset; the bare keys are
// the AX-probe emit threads. Anchored patterns only — never substring matches.
let demoLike = "demo-%"
let emitKeys = ["poker", "sam", "sam-carter", "zo-m-ller-ta", "22395", "freshdirect"]

struct Doomed { let id: String; let platform: String; let pid: String; let title: String? }

do {
    let doomed: [Doomed] = try dbQueue.read { db in
        let keyList = emitKeys.map { "'\($0)'" }.joined(separator: ",")
        return try Row.fetchAll(db, sql: """
            select id, platform, platformThreadID, title from thread
            where platformThreadID like ? or platformThreadID in (\(keyList))
            """, arguments: [demoLike]).map {
            Doomed(id: ($0["id"] as UUID? )?.uuidString ?? "\($0["id"] as Any)",
                   platform: $0["platform"] ?? "?",
                   pid: $0["platformThreadID"] ?? "?",
                   title: $0["title"])
        }
    }
    let byPlatform = Dictionary(grouping: doomed, by: \.platform).mapValues(\.count)
    let total = try dbQueue.read { db in
        try Int.fetchOne(db, sql: "select count(*) from thread") ?? 0
    }
    print("store: \(total) threads total; \(doomed.count) mock-origin:")
    for (platform, n) in byPlatform.sorted(by: { $0.key < $1.key }) {
        print("  \(platform): \(n)")
    }
    guard !doomed.isEmpty else { print("nothing to purge."); exit(0) }
    guard apply else { print("\ndry run — pass --apply to delete."); exit(0) }

    try dbQueue.write { db in
        let keyList = emitKeys.map { "'\($0)'" }.joined(separator: ",")
        let idSelect = """
            select id from thread
            where platformThreadID like '\(demoLike)' or platformThreadID in (\(keyList))
            """
        let msgSelect = "select id from message where threadID in (\(idSelect))"
        for sql in [
            "delete from message_reaction where targetMessageID in (\(msgSelect))",
            "delete from message_attachment where messageID in (\(msgSelect))",
            "delete from message where threadID in (\(idSelect))",
            "delete from thread where id in (\(idSelect))",
            // contacts that no longer author anything and match demo shapes
            """
            delete from contact where id not in (select distinct senderContactID from message
                                                 where senderContactID is not null)
              and (handle like 'urn:li:member:%' or handle like '+1415555%'
                   or handle like 'demo-%' or handle like '%pokernight%' or handle like 'noreply@updates.%')
            """,
        ] {
            try db.execute(sql: sql)
            print("  ✓ \(db.changesCount) rows: \(sql.prefix(58))…")
        }
    }
    try dbQueue.vacuum()
    let after = try dbQueue.read { db in
        try Int.fetchOne(db, sql: "select count(*) from thread") ?? 0
    }
    print("done. \(total) → \(after) threads.")
} catch {
    print("✗ purge failed: \(error)"); exit(1)
}
