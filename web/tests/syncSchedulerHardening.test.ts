// W2 review hardening: re-entrancy guard, degraded-status re-check, the
// stale/tick clamp, fan-out stagger, and the scheduler's own start-up gates —
// all found untested (or unenforced) by an adversarial review of the initial
// diff. See web/lib/connections/resync.ts and web/lib/sync/scheduler.ts.

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { getStore, resetStoreForTests } from "@/lib/connections/memoryStore";
import { resetAccountsForTests, getAccounts } from "@/lib/accounts/store";
import { resyncConnection } from "@/lib/connections/resync";
import { runTick, startIncrementalSyncScheduler, resetSchedulerForTests, type TickDeps } from "@/lib/sync/scheduler";
import { backfillConnection } from "@/lib/connections/backfill";
import { markConnectionDegraded } from "@/lib/connections/degrade";
import type { Connection } from "@/lib/connections/types";

vi.mock("@/lib/connections/backfill", () => ({ backfillConnection: vi.fn(async () => {}) }));
vi.mock("@/lib/oauth/tokens", () => ({
  freshOAuthToken: vi.fn(async () => ({ access_token: "tok" })),
}));

beforeEach(() => { resetStoreForTests(); resetAccountsForTests(); resetSchedulerForTests(); vi.clearAllMocks(); });
afterEach(() => {
  resetSchedulerForTests();
  delete process.env.SUPABASE_URL;
  delete process.env.SUPABASE_SERVICE_ROLE_KEY;
  delete process.env.OSMO_ALLOW_DURABLE_DEV;
  vi.restoreAllMocks();
});

function conn(over: Partial<Connection> = {}): Connection {
  return {
    id: "c1", deviceId: "d1", platform: "linkedin", status: "connected",
    displayName: "LI", backfillProgress: 1, createdAt: "2026-01-01T00:00:00Z",
    lastSyncAt: null, ...over,
  };
}

describe("resyncConnection — re-entrancy", () => {
  it("a connection already backfilling is a no-op success, not a second run", async () => {
    const store = getStore();
    const device = store.registerDevice();
    store.hydrateConnection(conn({ id: "c1", deviceId: device.id, status: "backfilling", backfillProgress: 0.4 }));

    const result = await resyncConnection(device.id, "c1", "linkedin");
    expect(result).toEqual({ ok: true });
    expect(backfillConnection).not.toHaveBeenCalled();
    // progress must NOT be reset by the no-op
    expect(store.connectionById("c1")?.backfillProgress).toBe(0.4);
  });
});

describe("resyncConnection — degraded-token re-check", () => {
  it("a refresh failure that flips the connection to degraded is respected, not clobbered back to backfilling", async () => {
    const { freshOAuthToken } = await import("@/lib/oauth/tokens");
    const store = getStore();
    const device = store.registerDevice();
    store.hydrateConnection(conn({ id: "c-gmail", deviceId: device.id, platform: "gmail", status: "connected" }));
    process.env.GOOGLE_CLIENT_ID = "cid";
    process.env.GOOGLE_CLIENT_SECRET = "sec";

    vi.mocked(freshOAuthToken).mockImplementationOnce(async () => {
      // exactly what the real freshOAuthToken does on a failed refresh: mark
      // degraded, then still return the stale (truthy) bundle.
      markConnectionDegraded(device.id, "gmail");
      return { access_token: "stale-token" };
    });

    const result = await resyncConnection(device.id, "c-gmail", "gmail");
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.status).toBe(409);
    expect(store.connectionById("c-gmail")?.status).toBe("degraded");

    delete process.env.GOOGLE_CLIENT_ID;
    delete process.env.GOOGLE_CLIENT_SECRET;
  });
});

function makeDeps(over: Partial<TickDeps> = {}): TickDeps & { resyncCalls: string[] } {
  const resyncCalls: string[] = [];
  return {
    listConnections: vi.fn(async () => []),
    ensureLoaded: vi.fn(async () => {}),
    resync: vi.fn(async (_d, id) => { resyncCalls.push(id); return { ok: true as const }; }),
    now: () => Date.parse("2026-07-11T12:00:00Z"),
    resyncCalls,
    ...over,
  };
}

describe("runTick — stale/tick clamp", () => {
  it("staleAfterMs is clamped to never fall below tickIntervalMs, even if OSMO_SYNC_STALE_MS is set lower", async () => {
    process.env.OSMO_SYNC_TICK_MS = "300000";  // 5 min
    process.env.OSMO_SYNC_STALE_MS = "60000";  // 1 min — would be unsafe unclamped
    const now = Date.parse("2026-07-11T12:00:00Z");
    // Synced 2 minutes ago: past the requested 1-min staleness, but inside
    // the clamped 5-min floor — must NOT be due.
    const synced2MinAgo = new Date(now - 2 * 60_000).toISOString();
    const deps = makeDeps({
      listConnections: async () => [conn({ id: "recent", lastSyncAt: synced2MinAgo })],
      now: () => now,
    });
    const result = await runTick(deps);
    expect(result.attempted).toEqual([]);
    delete process.env.OSMO_SYNC_TICK_MS;
    delete process.env.OSMO_SYNC_STALE_MS;
  });
});

describe("runTick — fan-out stagger", () => {
  it("sleeps between due connections but not before the first or after the last", async () => {
    const sleepCalls: number[] = [];
    const deps = makeDeps({
      listConnections: async () => [conn({ id: "a" }), conn({ id: "b" }), conn({ id: "c" })],
      sleep: vi.fn(async (ms: number) => { sleepCalls.push(ms); }),
    });
    await runTick(deps);
    expect(sleepCalls.length).toBe(2); // 2 gaps between 3 items
  });

  it("omitting sleep (as every pre-existing test's deps do) never throws", async () => {
    const deps = makeDeps({ listConnections: async () => [conn({ id: "a" }), conn({ id: "b" })] });
    const result = await runTick(deps);
    expect(result.attempted).toEqual(["a", "b"]);
  });
});

describe("startIncrementalSyncScheduler", () => {
  it("never arms a timer when accounts are not live (mock/dev/test — the default here)", () => {
    const spy = vi.spyOn(global, "setInterval");
    startIncrementalSyncScheduler();
    expect(spy).not.toHaveBeenCalled();
  });

  it("is idempotent — a second call does not register a second timer", () => {
    process.env.SUPABASE_URL = "https://x.supabase.co";
    process.env.SUPABASE_SERVICE_ROLE_KEY = "key";
    process.env.OSMO_ALLOW_DURABLE_DEV = "1";
    const spy = vi.spyOn(global, "setInterval").mockReturnValue(1 as unknown as NodeJS.Timeout);
    startIncrementalSyncScheduler();
    startIncrementalSyncScheduler();
    expect(spy).toHaveBeenCalledTimes(1);
  });
});

describe("connectedConnectionsByPlatforms — the scheduler's only pause guard", () => {
  it("returns only connected rows on the requested platforms, excluding paused/degraded/disconnected", async () => {
    resetAccountsForTests();
    const store = getAccounts();
    await store.upsertConnection(conn({ id: "gmail-connected", deviceId: "d1", platform: "gmail", status: "connected" }));
    await store.upsertConnection(conn({ id: "gmail-paused", deviceId: "d1", platform: "gmail", status: "paused" }));
    await store.upsertConnection(conn({ id: "slack-degraded", deviceId: "d2", platform: "slack", status: "degraded" }));
    await store.upsertConnection(conn({ id: "x-connected", deviceId: "d3", platform: "x", status: "connected" }));
    await store.upsertConnection(conn({ id: "linkedin-connected", deviceId: "d4", platform: "linkedin", status: "connected" }));

    const due = await store.connectedConnectionsByPlatforms(["gmail", "slack", "x"]);
    expect(due.map(c => c.id).sort()).toEqual(["gmail-connected", "x-connected"]);
  });
});
