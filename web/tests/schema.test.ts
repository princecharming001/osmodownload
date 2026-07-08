// Schema drift guard — the green/red signal for the migration work. No database
// required: it parses web/db/migrations/*.sql statically and asserts every table
// + column the accounts store (lib/accounts/store.ts) relies on is declared.
//
// The CONTRACT below is the column set store.ts reads/writes. If you teach the
// store a new column, add it here AND to a migration — this test enforces that.

import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

const MIGRATIONS_DIR = join(process.cwd(), "db/migrations");

// table → required columns (derived from SupabaseAccountsStore in store.ts)
const CONTRACT: Record<string, string[]> = {
  osmo_users: ["id", "email", "apple_user_id", "display_name", "created_at"],
  osmo_devices: ["id", "token", "user_id", "created_at", "last_seen_at"],
  osmo_subscriptions: [
    "owner_type", "owner_id", "license_key", "subscription_active", "plan", "trial_started_at", "updated_at",
  ],
  osmo_magic_links: ["token", "email", "expires_at", "used"],
  osmo_web_sessions: ["token", "user_id", "created_at"],
};

function allMigrationSQL(): string {
  return readdirSync(MIGRATIONS_DIR)
    .filter((f) => f.endsWith(".sql"))
    .sort()
    .map((f) => readFileSync(join(MIGRATIONS_DIR, f), "utf8"))
    .join("\n");
}

// Pull the parenthesised body of `create table [if not exists] <name> ( ... )`
// and return the leading identifier of each top-level definition (columns +
// constraint keywords; callers filter to the contract). Strips SQL comments and
// splits only on TOP-LEVEL commas so inline `check (a in ('x','y'))` and
// `references t(id)` don't fragment a definition.
function declaredColumns(sql: string, table: string): Set<string> {
  const re = new RegExp(`create\\s+table\\s+(?:if\\s+not\\s+exists\\s+)?${table}\\s*\\(`, "i");
  const m = re.exec(sql);
  if (!m) return new Set();
  let depth = 0, body = "", started = false;
  for (let i = m.index + m[0].length - 1; i < sql.length; i++) {
    const c = sql[i];
    if (c === "(") { depth++; if (depth === 1) { started = true; continue; } }
    if (c === ")") { depth--; if (depth === 0) break; }
    if (started) body += c;
  }
  body = body.replace(/--[^\n]*/g, ""); // drop line comments

  const parts: string[] = [];
  let d = 0, cur = "";
  for (const c of body) {
    if (c === "(") d++;
    else if (c === ")") d--;
    if (c === "," && d === 0) { parts.push(cur); cur = ""; }
    else cur += c;
  }
  if (cur.trim()) parts.push(cur);

  const cols = new Set<string>();
  for (const part of parts) {
    const line = part.trim();
    if (!line) continue;
    cols.add(line.split(/\s+/)[0].toLowerCase());
  }
  return cols;
}

// 0-B durable state (Appendix C) — key columns per table.
const DURABLE_CONTRACT: Record<string, string[]> = {
  osmo_oplog: ["device_id", "seq", "native_key", "content_hash", "payload"],
  osmo_oplog_seq: ["device_id", "next_seq"],
  osmo_oauth_tokens: ["device_id", "platform", "tokens", "obtained_at"],
  osmo_connections: ["id", "device_id", "platform", "status"],
  osmo_pending_links: ["link_id", "device_id", "platform", "code_verifier", "used"],
  osmo_quota_counters: ["account_id", "week_start", "count"],
  osmo_rate_limits: ["bucket_key", "count", "reset_at"],
  osmo_spend_counters: ["period_key", "count"],
  osmo_send_outbox: ["idempotency_key", "device_id", "status", "attempts", "message"],
  osmo_events: ["id", "device_id", "seq", "type"],
  osmo_processed_events: ["event_id", "source"],
  osmo_promo_codes: ["code", "kind", "value", "max_uses", "used_count"],
  osmo_promo_redemptions: ["code", "account_id"],
  osmo_intel_cache: ["account_id", "thread_id", "last_message_id", "intel"],
  osmo_enrichment_cache: ["cache_key", "device_id", "source"],
  osmo_precomputed_draft: ["account_id", "thread_id", "draftset", "lineage_id"],
  osmo_config_registry: ["id", "registry"],
  osmo_feedback: ["id", "message", "meta"],
};

describe("db schema drift guard", () => {
  const sql = allMigrationSQL();

  for (const [table, cols] of Object.entries({ ...CONTRACT, ...DURABLE_CONTRACT })) {
    it(`${table} declares every column the store uses`, () => {
      const declared = declaredColumns(sql, table);
      expect(declared.size, `no CREATE TABLE ${table} found in migrations`).toBeGreaterThan(0);
      for (const col of cols) {
        expect(declared.has(col), `migrations are missing ${table}.${col}`).toBe(true);
      }
    });
  }
});
