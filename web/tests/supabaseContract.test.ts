// Contract test for the REAL SupabaseAccountsStore against a faithful in-memory
// fake of the supabase-js query builder — so the durable code (snake_case column
// maps, onConflict targets, the usage RPCs, ignoreDuplicates dedup) is actually
// exercised. Every OTHER test uses the in-memory fallback, so this is the only
// coverage of the production durable path.

import { describe, expect, it, beforeEach } from "vitest";
import { SupabaseAccountsStore } from "@/lib/accounts/store";

// ── a tiny fake of the subset of supabase-js the store uses ───────────────────
type Row = Record<string, unknown>;
class FakeDB { tables = new Map<string, Row[]>(); t(n: string): Row[] { if (!this.tables.has(n)) this.tables.set(n, []); return this.tables.get(n)!; } }

class Q {
  private filters: [string, unknown][] = [];
  private mut?: { kind: "upsert" | "insert" | "update" | "delete"; rows?: Row[]; patch?: Row; onConflict?: string; ignoreDuplicates?: boolean };
  constructor(private db: FakeDB, private name: string) {}
  select() { return this; }
  eq(c: string, v: unknown) { this.filters.push([c, v]); return this; }
  order() { return this; }
  upsert(rows: Row | Row[], opts?: { onConflict?: string; ignoreDuplicates?: boolean }) {
    this.mut = { kind: "upsert", rows: Array.isArray(rows) ? rows : [rows], onConflict: opts?.onConflict, ignoreDuplicates: opts?.ignoreDuplicates }; return this;
  }
  insert(rows: Row | Row[]) { this.mut = { kind: "insert", rows: Array.isArray(rows) ? rows : [rows] }; return this; }
  update(patch: Row) { this.mut = { kind: "update", patch }; return this; }
  delete() { this.mut = { kind: "delete" }; return this; }
  private match(r: Row) { return this.filters.every(([c, v]) => r[c] === v); }
  private run(): Row[] {
    const rows = this.db.t(this.name);
    if (!this.mut) return rows.filter((r) => this.match(r));
    if (this.mut.kind === "delete") { const del = rows.filter((r) => this.match(r)); del.forEach((d) => rows.splice(rows.indexOf(d), 1)); return del; }
    if (this.mut.kind === "update") { const upd = rows.filter((r) => this.match(r)); upd.forEach((u) => Object.assign(u, this.mut!.patch)); return upd; }
    const pk = this.mut.onConflict?.split(",").map((s) => s.trim()) ?? [];
    const out: Row[] = [];
    for (const nr of this.mut.rows!) {
      const existing = pk.length ? rows.find((r) => pk.every((k) => r[k] === nr[k])) : undefined;
      if (existing) { if (this.mut.ignoreDuplicates) continue; Object.assign(existing, nr); out.push(existing); }
      else { const row = { ...nr }; rows.push(row); out.push(row); }
    }
    return out;
  }
  maybeSingle() { const r = this.run(); return Promise.resolve({ data: r[0] ?? null, error: null }); }
  single() { const r = this.run(); return Promise.resolve({ data: r[0] ?? null, error: r[0] ? null : { message: "no rows" } }); }
  then(res: (v: { data: Row[]; error: null }) => void) { res({ data: this.run(), error: null }); }
}

class FakeClient {
  constructor(private db: FakeDB) {}
  from(name: string) { return new Q(this.db, name); }
  rpc(fn: string, args: { p_device_id: string; p_week_start: number }) {
    const usage = this.db.t("osmo_usage");
    let row = usage.find((r) => r.device_id === args.p_device_id) as { device_id: string; week_start: number; count: number } | undefined;
    if (fn === "osmo_bump_usage") {
      if (!row) { row = { device_id: args.p_device_id, week_start: args.p_week_start, count: 1 }; usage.push(row); }
      else { row.count = row.week_start === args.p_week_start ? row.count + 1 : 1; row.week_start = args.p_week_start; }
      return Promise.resolve({ data: row.count, error: null });
    }
    if (fn === "osmo_refund_usage") {
      if (row && row.week_start === args.p_week_start) row.count = Math.max(0, row.count - 1);
      return Promise.resolve({ data: row?.count ?? 0, error: null });
    }
    return Promise.resolve({ data: null, error: { message: "unknown rpc" } });
  }
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function store() { return new SupabaseAccountsStore(new FakeClient(new FakeDB()) as any); }

describe("SupabaseAccountsStore contract (durable code path)", () => {
  let s: ReturnType<typeof store>;
  beforeEach(() => { s = store(); });

  it("devices: upsert + lookup by id and token", async () => {
    await s.upsertDevice("dev-1", "tok-1");
    expect((await s.deviceById("dev-1"))?.id).toBe("dev-1");
    expect((await s.deviceByToken("tok-1"))?.id).toBe("dev-1");
    expect(await s.deviceByToken("nope")).toBeNull();
  });

  it("subscriptions: device sub round-trips with snake_case columns", async () => {
    await s.upsertDevice("dev-2", "tok-2");
    await s.setSubscriptionForDevice("dev-2", { subscriptionActive: true, plan: "com.osmo.pro.monthly", licenseKey: "STRIPE" });
    const sub = await s.subscriptionForDevice("dev-2");
    expect(sub.subscriptionActive).toBe(true);
    expect(sub.plan).toBe("com.osmo.pro.monthly");
  });

  it("usage: atomic bump/refund RPC + week reset", async () => {
    expect(await s.bumpUsage("dev-3", 1000)).toBe(1);
    expect(await s.bumpUsage("dev-3", 1000)).toBe(2);
    expect(await s.refundUsage("dev-3", 1000)).toBe(1);
    expect(await s.usageCount("dev-3", 1000)).toBe(1);
    expect(await s.bumpUsage("dev-3", 2000)).toBe(1); // new week resets
    expect(await s.usageCount("dev-3", 1000)).toBe(0); // old week no longer current
  });

  it("oauth tokens + connections round-trip", async () => {
    await s.setOAuthTokens("dev-4", "gmail", { access_token: "a" });
    expect((await s.oauthTokens("dev-4", "gmail"))?.access_token).toBe("a");
    await s.upsertConnection({ id: "c1", deviceId: "dev-4", platform: "gmail", status: "connected", displayName: "G", backfillProgress: 1, createdAt: "2026-01-01" });
    const conns = await s.connectionsForDevice("dev-4");
    expect(conns).toHaveLength(1);
    expect(conns[0].status).toBe("connected");
    await s.deleteConnection("c1");
    expect(await s.connectionsForDevice("dev-4")).toHaveLength(0);
  });

  it("event idempotency: first true, redelivery false (ignoreDuplicates)", async () => {
    expect(await s.markEventProcessed("evt_1", "stripe")).toBe(true);
    expect(await s.markEventProcessed("evt_1", "stripe")).toBe(false);
  });
});
