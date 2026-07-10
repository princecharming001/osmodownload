// POST /api/connect/rebackfill — per-platform dispatch. The old bug: EVERY
// platform was sent into the Unipile importer, so a Gmail/Slack/X "Re-import
// history" silently no-oped. The importers are mocked; the assertion is purely
// which one the route picks (and with which credentials).

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { getStore, resetStoreForTests } from "@/lib/connections/memoryStore";
import { resetAccountsForTests } from "@/lib/accounts/store";
import { backfillConnection } from "@/lib/connections/backfill";
import { backfillGmail } from "@/lib/oauth/gmailBackfill";
import { backfillSlack } from "@/lib/oauth/slackBackfill";
import { backfillX } from "@/lib/oauth/xBackfill";
import { POST as rebackfill } from "@/app/api/connect/rebackfill/route";
import type { Connection, Platform } from "@/lib/connections/types";

vi.mock("@/lib/connections/backfill", () => ({ backfillConnection: vi.fn(async () => {}) }));
vi.mock("@/lib/oauth/gmailBackfill", () => ({ backfillGmail: vi.fn(async () => {}) }));
vi.mock("@/lib/oauth/slackBackfill", () => ({ backfillSlack: vi.fn(async () => {}) }));
vi.mock("@/lib/oauth/xBackfill", () => ({ backfillX: vi.fn(async () => {}) }));

const BASE = "http://localhost:3000";

function post(platform: Platform, token: string): Request {
  return new Request(`${BASE}/api/connect/rebackfill`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: JSON.stringify({ platform }),
  });
}

function connection(id: string, deviceId: string, platform: Platform): Connection {
  return {
    id, deviceId, platform, status: "connected",
    displayName: platform, backfillProgress: 1, createdAt: new Date().toISOString(),
  };
}

/** Let the route's fire-and-forget `void run()` land. */
const tick = () => new Promise((r) => setTimeout(r, 0));

beforeEach(() => { resetStoreForTests(); resetAccountsForTests(); vi.clearAllMocks(); });
afterEach(() => {
  delete process.env.GOOGLE_CLIENT_ID;
  delete process.env.GOOGLE_CLIENT_SECRET;
});

describe("rebackfill — per-platform dispatch", () => {
  it("gmail goes through the Gmail importer with the stored OAuth token", async () => {
    const store = getStore();
    const device = store.registerDevice();
    store.addConnection(connection("c-gmail", device.id, "gmail"));
    store.setOAuthTokens(device.id, "gmail", { access_token: "gtok" });

    const res = await rebackfill(post("gmail", device.token));
    expect(res.status).toBe(200);
    await tick();
    expect(backfillGmail).toHaveBeenCalledWith(device.id, "c-gmail", "gtok");
    expect(backfillConnection).not.toHaveBeenCalled();
    // The importers' stop-check needs the status to actually be "backfilling".
    expect(store.connectionById("c-gmail")?.status).toBe("backfilling");
  });

  it("slack goes through the Slack importer with user token + id + team", async () => {
    const store = getStore();
    const device = store.registerDevice();
    store.addConnection(connection("c-slack", device.id, "slack"));
    store.setOAuthTokens(device.id, "slack", {
      authed_user: { access_token: "stok", id: "U1" }, team: { id: "T1" },
    });

    expect((await rebackfill(post("slack", device.token))).status).toBe(200);
    await tick();
    expect(backfillSlack).toHaveBeenCalledWith(device.id, "c-slack", "stok", "U1", "T1");
    expect(backfillConnection).not.toHaveBeenCalled();
  });

  it("x goes through the X importer", async () => {
    const store = getStore();
    const device = store.registerDevice();
    store.addConnection(connection("c-x", device.id, "x"));
    store.setOAuthTokens(device.id, "x", { access_token: "xtok" });

    expect((await rebackfill(post("x", device.token))).status).toBe(200);
    await tick();
    expect(backfillX).toHaveBeenCalledWith(device.id, "c-x", "xtok");
    expect(backfillConnection).not.toHaveBeenCalled();
  });

  it("unipile platforms still go through the Unipile importer", async () => {
    const store = getStore();
    const device = store.registerDevice();
    store.addConnection(connection("acc-li", device.id, "linkedin"));

    expect((await rebackfill(post("linkedin", device.token))).status).toBe(200);
    await tick();
    expect(backfillConnection).toHaveBeenCalledWith({
      deviceId: device.id, accountId: "acc-li", platform: "linkedin",
    });
    expect(backfillGmail).not.toHaveBeenCalled();
  });

  it("live OAuth + missing token → 409 reconnect (never stranded in backfilling)", async () => {
    process.env.GOOGLE_CLIENT_ID = "cid";
    process.env.GOOGLE_CLIENT_SECRET = "sec";
    const store = getStore();
    const device = store.registerDevice();
    store.addConnection(connection("c-gmail", device.id, "gmail"));

    const res = await rebackfill(post("gmail", device.token));
    expect(res.status).toBe(409);
    expect(store.connectionById("c-gmail")?.status).toBe("connected");
    expect(backfillGmail).not.toHaveBeenCalled();
  });

  it("keyless mock connection without tokens falls back to the Unipile no-op (200)", async () => {
    const store = getStore();
    const device = store.registerDevice();
    store.addConnection(connection("c-gmail", device.id, "gmail"));

    expect((await rebackfill(post("gmail", device.token))).status).toBe(200);
    await tick();
    expect(backfillConnection).toHaveBeenCalled();
    expect(backfillGmail).not.toHaveBeenCalled();
  });
});
