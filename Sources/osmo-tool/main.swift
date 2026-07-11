import Foundation
import GRDB
import OsmoCore

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
guard let cmd = args.first, ["purge-demo", "inspect", "media", "groups", "probe-chatdb", "repair-groups", "clear-enrichment"].contains(cmd) else {
    print("usage: osmo-tool purge-demo [--apply] | inspect [name-fragment] | media | groups | probe-chatdb | repair-groups [--apply] | clear-enrichment [--apply]"); exit(2)
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

// groups — read-only probe: are group chats detected, and is every incoming
// group message attributed to a named sender? (The AI layer labels group turns
// by sender, so unattributed incoming messages in groups = degraded context.)
// probe-chatdb — read-only: run the CURRENT reader+normalizer over the real
// Messages chat.db and report how many threads would be groups. Never writes.
if cmd == "probe-chatdb" {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let chatDB = home.appendingPathComponent("Library/Messages/chat.db")
    do {
        // Recent slice only — a full readAll blows the SQL-variable cap in the
        // attachment batch join on very large DBs (the app imports in chunks).
        let sinceRow = Int64(255549 - 2500)
        let (raws, _) = try ChatDBReader(path: chatDB).readSince(rowID: sinceRow)
        let batch = IMessageNormalizer.normalize(raws)
        let groups = batch.threads.filter(\.isGroup)
        print("raw rows: \(raws.count)")
        print("normalized: \(batch.threads.count) threads (\(groups.count) group), \(batch.messages.count) messages, \(batch.contacts.count) contacts")
        let attributed = batch.messages.filter { !$0.isFromMe && $0.senderContactID != nil }.count
        let incoming = batch.messages.filter { !$0.isFromMe }.count
        print("incoming messages: \(incoming), sender-attributed: \(attributed)")
        for g in groups.sorted(by: { ($0.lastMessageAt ?? .distantPast) > ($1.lastMessageAt ?? .distantPast) }).prefix(5) {
            print("  group: \(g.title ?? "(untitled)") [\(g.platformThreadID.prefix(18))…]")
        }
    } catch { print("✗ probe failed: \(error)"); exit(1) }
    exit(0)
}

if cmd == "repair-groups" {
    // Same rule as OsmoStore.repairGroupFlags(): 2+ distinct non-me senders on
    // a messaging platform = group, whatever the provider claimed.
    do {
        let candidates = try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                select t.id, t.platform, t.title,
                       (select count(distinct m.senderContactID) from message m
                        where m.threadID = t.id and m.isFromMe = 0
                          and m.senderContactID is not null and m.deletedAt is null) senders
                from thread t
                where t.isGroup = 0 and t.deletedAt is null
                  and t.platform in ('imessage','whatsapp','instagram','linkedin','x')
                  and (select count(distinct m.senderContactID) from message m
                       where m.threadID = t.id and m.isFromMe = 0
                         and m.senderContactID is not null and m.deletedAt is null) >= 2
                """)
        }
        print("\(candidates.count) thread(s) are actually groups:")
        for r in candidates {
            print("  [\(r["platform"] as String? ?? "?")] \(r["title"] as String? ?? "(untitled)") — \(r["senders"] as Int? ?? 0) senders")
        }
        guard !candidates.isEmpty else { exit(0) }
        guard apply else { print("\ndry run — pass --apply to flip isGroup."); exit(0) }
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE thread SET isGroup = 1
                WHERE isGroup = 0 AND deletedAt IS NULL
                  AND platform IN ('imessage','whatsapp','instagram','linkedin','x')
                  AND id IN (SELECT threadID FROM message
                             WHERE isFromMe = 0 AND senderContactID IS NOT NULL
                               AND deletedAt IS NULL
                             GROUP BY threadID
                             HAVING COUNT(DISTINCT senderContactID) >= 2)
                """)
            print("flipped \(db.changesCount) thread(s) to isGroup = 1.")
        }
    } catch { print("✗ repair failed: \(error)"); exit(1) }
    exit(0)
}

if cmd == "clear-enrichment" {
    // person_enrichment is a RE-FETCHABLE cache. Wiping it is the clean way
    // out of poisoned rows (e.g. a group title "Tejas and Maddi" web-searched
    // into fighter-jet facts) — profiles refetch lazily with correct names.
    do {
        let n = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "select count(*) from person_enrichment") ?? 0
        }
        print("\(n) cached enrichment row(s).")
        guard n > 0 else { exit(0) }
        guard apply else { print("dry run — pass --apply to clear the cache."); exit(0) }
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM person_enrichment")
            print("cleared \(db.changesCount) row(s) — they refetch lazily with correct names.")
        }
    } catch { print("✗ clear failed: \(error)"); exit(1) }
    exit(0)
}

if cmd == "groups" {
    do {
        try dbQueue.read { db in
            let total = try Int.fetchOne(db, sql: "select count(*) from thread where deletedAt is null") ?? 0
            let groups = try Int.fetchOne(db, sql: "select count(*) from thread where isGroup = 1 and deletedAt is null") ?? 0
            print("threads: \(total) total, \(groups) group")

            let cov = try Row.fetchOne(db, sql: """
                select count(*) n,
                       sum(case when m.senderContactID is not null then 1 else 0 end) attributed
                from message m join thread t on t.id = m.threadID
                where t.isGroup = 1 and m.isFromMe = 0 and m.deletedAt is null
                """)
            let n = (cov?["n"] as Int?) ?? 0
            let attributed = (cov?["attributed"] as Int?) ?? 0
            print("incoming group messages: \(n), sender-attributed: \(attributed)"
                  + (n > 0 ? String(format: " (%.1f%%)", 100.0 * Double(attributed) / Double(n)) : ""))

            print("\ntop group threads:")
            for r in try Row.fetchAll(db, sql: """
                select t.id, t.title, t.platform, t.lastMessageAt,
                       (select count(distinct m.senderContactID) from message m
                        where m.threadID = t.id and m.senderContactID is not null) senders,
                       (select count(*) from message m where m.threadID = t.id and m.deletedAt is null) msgs
                from thread t where t.isGroup = 1 and t.deletedAt is null
                order by t.lastMessageAt desc limit 10
                """) {
                let tid = (r["id"] as UUID?)?.uuidString ?? (r["id"] as String? ?? "")
                print("  [\(r["platform"] as String? ?? "?")] \(r["title"] as String? ?? "(untitled)") — \(r["msgs"] as Int? ?? 0) msgs, \(r["senders"] as Int? ?? 0) senders")
                for m in try Row.fetchAll(db, sql: """
                    select coalesce(c.displayName, c.handle, case when m.isFromMe = 1 then 'me' else '???' end) who,
                           count(*) n
                    from message m left join contact c on c.id = m.senderContactID
                    where m.threadID = ? and m.deletedAt is null
                    group by who order by n desc limit 6
                    """, arguments: [r["id"] as UUID? ?? tid]) {
                    print("      \(m["who"] as String? ?? "?"): \(m["n"] as Int? ?? 0)")
                }
            }
        }
    } catch { print("✗ groups failed: \(error)"); exit(1) }
    exit(0)
}

if cmd == "media" {
    do {
        try dbQueue.read { db in
            print("── attachments by kind × platform ──")
            for r in try Row.fetchAll(db, sql: """
                select m.platform, a.kind, count(*) n from message_attachment a
                join message m on m.id = a.messageID
                group by m.platform, a.kind order by n desc limit 20
                """) {
                print("  \(r["platform"] as String? ?? "?") \(r["kind"] as String? ?? "?"): \(r["n"] as Int? ?? 0)")
            }
            print("── attachment total ──")
            print("  \(try Int.fetchOne(db, sql: "select count(*) from message_attachment") ?? 0)")
            print("── empty-text messages by platform (media-only?) ──")
            for r in try Row.fetchAll(db, sql: """
                select platform, count(*) n from message
                where length(trim(text)) = 0 group by platform order by n desc limit 8
                """) {
                print("  \(r["platform"] as String? ?? "?"): \(r["n"] as Int? ?? 0)")
            }
            print("── messages with URLs by platform ──")
            for r in try Row.fetchAll(db, sql: """
                select platform, count(*) n from message
                where text like '%http%' group by platform order by n desc limit 8
                """) {
                print("  \(r["platform"] as String? ?? "?"): \(r["n"] as Int? ?? 0)")
            }
            print("── empty-text messages WITHOUT any attachment row (invisible bubbles) ──")
            for r in try Row.fetchAll(db, sql: """
                select m.platform, count(*) n from message m
                where length(trim(m.text)) = 0 and m.deletedAt is null
                  and not exists (select 1 from message_attachment a where a.messageID = m.id)
                group by m.platform order by n desc limit 8
                """) {
                print("  \(r["platform"] as String? ?? "?"): \(r["n"] as Int? ?? 0)")
            }
            print("── sample link-attachment titles/urls (instagram) ──")
            for r in try Row.fetchAll(db, sql: """
                select substr(coalesce(a.title,'-'),1,40) t, substr(coalesce(a.linkURL,'-'),1,70) u
                from message_attachment a join message m on m.id = a.messageID
                where a.kind = 'link' and m.platform = 'instagram' limit 6
                """) {
                print("  title=\(r["t"] as String? ?? "-") url=\(r["u"] as String? ?? "-")")
            }
            print("── instagram/whatsapp sample texts (recent 8) ──")
            for r in try Row.fetchAll(db, sql: """
                select platform, substr(replace(text, char(10), ' '), 1, 90) t from message
                where platform in ('instagram','whatsapp') and deletedAt is null
                order by sentAt desc limit 8
                """) {
                print("  [\(r["platform"] as String? ?? "?")] \(r["t"] as String? ?? "")")
            }
        }
    } catch { print("✗ media census failed: \(error)"); exit(1) }
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

    // person_enrichment is a SEPARATE cache from threads/messages — fabricated
    // profiles ("Recruiter at Parallel AI", news.example.com links) fetched
    // while the app mistakenly believed it was in mock mode (round-6 bug) and
    // cached with source='mock'. It survives a thread purge untouched, so it
    // needs its own sweep — this was the "still showing demo data" report
    // AFTER the thread-level purge already read clean.
    let mockEnrichmentCount = try dbQueue.read { db in
        try Int.fetchOne(db, sql: "select count(*) from person_enrichment where source = 'mock'") ?? 0
    }
    print("\(mockEnrichmentCount) mock-origin person_enrichment row(s) (source='mock').")

    guard !doomed.isEmpty || mockEnrichmentCount > 0 else { print("nothing to purge."); exit(0) }
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
            "delete from person_enrichment where source = 'mock'",
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
