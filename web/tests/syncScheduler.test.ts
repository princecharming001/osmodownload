// The incremental sync scheduler: which connections are "due", the fan-out
// never stops on one failure, and a stale-but-successful connection's
// watermark is respected. Fully dependency-injected — no real durable store,
// no real provider calls, no timers.

import { describe, expect, it, vi } from "vitest";
import { runTick, type TickDeps } from "@/lib/sync/scheduler";
import type { Connection } from "@/lib/connections/types";

const NOW = Date.parse("2026-07-11T12:00:00Z");

function conn(over: Partial<Connection> = {}): Connection {
  return {
    id: "c1", deviceId: "d1", platform: "gmail", status: "connected",
    displayName: "Gmail", backfillProgress: 1, createdAt: "2026-01-01T00:00:00Z",
    lastSyncAt: null, ...over,
  };
}

function makeDeps(over: Partial<TickDeps> = {}): TickDeps & { resyncCalls: string[] } {
  const resyncCalls: string[] = [];
  return {
    listConnections: vi.fn(async () => []),
    ensureLoaded: vi.fn(async () => {}),
    resync: vi.fn(async (_d, id) => { resyncCalls.push(id); return { ok: true as const }; }),
    now: () => NOW,
    resyncCalls,
    ...over,
  };
}

describe("runTick — staleness gating", () => {
  it("a connection with no lastSyncAt is always due", async () => {
    const deps = makeDeps({ listConnections: async () => [conn({ id: "never-synced", lastSyncAt: null })] });
    const result = await runTick(deps);
    expect(result.attempted).toEqual(["never-synced"]);
    expect(deps.resyncCalls).toEqual(["never-synced"]);
  });

  it("a connection synced 5 minutes ago is NOT due (10-min default threshold)", async () => {
    const fresh = new Date(NOW - 5 * 60_000).toISOString();
    const deps = makeDeps({ listConnections: async () => [conn({ id: "fresh", lastSyncAt: fresh })] });
    const result = await runTick(deps);
    expect(result.attempted).toEqual([]);
    expect(deps.resyncCalls).toEqual([]);
  });

  it("a connection synced 15 minutes ago IS due", async () => {
    const stale = new Date(NOW - 15 * 60_000).toISOString();
    const deps = makeDeps({ listConnections: async () => [conn({ id: "stale", lastSyncAt: stale })] });
    const result = await runTick(deps);
    expect(result.attempted).toEqual(["stale"]);
  });
});

describe("runTick — fan-out resilience", () => {
  it("one connection throwing does not stop the others", async () => {
    const deps = makeDeps({
      listConnections: async () => [
        conn({ id: "a", platform: "gmail" }),
        conn({ id: "b", platform: "slack" }),
        conn({ id: "c", platform: "x" }),
      ],
      resync: vi.fn(async (_d, id) => {
        if (id === "b") throw new Error("token revoked");
        return { ok: true as const };
      }),
    });
    const result = await runTick(deps);
    expect(result.attempted).toEqual(["a", "b", "c"]);
    expect(result.failed).toEqual(["b"]);
  });

  it("a resync that returns ok:false is recorded as failed, not thrown", async () => {
    const deps = makeDeps({
      listConnections: async () => [conn({ id: "needs-reconnect" })],
      resync: vi.fn(async () => ({ ok: false as const, error: "reconnect gmail first", status: 409 })),
    });
    const result = await runTick(deps);
    expect(result.failed).toEqual(["needs-reconnect"]);
  });

  it("ensureLoaded is called before resync for every due connection (durable rehydration)", async () => {
    const calls: string[] = [];
    const deps = makeDeps({
      listConnections: async () => [conn({ id: "a", deviceId: "dev-a" })],
      ensureLoaded: vi.fn(async (deviceId: string) => { calls.push(`load:${deviceId}`); }),
      resync: vi.fn(async () => { calls.push("resync"); return { ok: true as const }; }),
    });
    await runTick(deps);
    expect(calls).toEqual(["load:dev-a", "resync"]);
  });

  it("a listConnections failure aborts the tick cleanly (no throw, nothing attempted)", async () => {
    const deps = makeDeps({ listConnections: async () => { throw new Error("supabase down"); } });
    const result = await runTick(deps);
    expect(result.attempted).toEqual([]);
    expect(result.failed).toEqual([]);
  });

  it("only gmail/slack/x are requested — Unipile platforms have real webhooks already", async () => {
    let requested: string[] = [];
    const deps = makeDeps({ listConnections: vi.fn(async (platforms: string[]) => { requested = platforms; return []; }) });
    await runTick(deps);
    expect(requested.sort()).toEqual(["gmail", "slack", "x"]);
  });
});
