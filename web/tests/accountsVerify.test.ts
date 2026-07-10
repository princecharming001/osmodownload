// GET /api/accounts?verify=1 — connection liveness (workstream D). Upstream
// Unipile account health flips connected↔degraded; fetch failures never touch
// statuses (no flapping); paused connections honour user intent; the whole
// thing is TTL-throttled and a no-op in keyless mode. Unipile HTTP is faked
// the repo way — live env vars + a stubbed global fetch.

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { getStore, resetStoreForTests } from "@/lib/connections/memoryStore";
import { resetAccountsForTests } from "@/lib/accounts/store";
import { resetLivenessForTests } from "@/lib/connections/liveness";
import { GET as accounts } from "@/app/api/accounts/route";
import { POST as unipileWebhook } from "@/app/api/webhooks/unipile/route";
import type { Connection, ConnectionStatus, Platform } from "@/lib/connections/types";

const BASE = "http://localhost:3000";

function get(token: string, verify = true): Request {
  return new Request(`${BASE}/api/accounts${verify ? "?verify=1" : ""}`, {
    headers: { authorization: `Bearer ${token}` },
  });
}

function connection(id: string, deviceId: string, platform: Platform, status: ConnectionStatus): Connection {
  return {
    id, deviceId, platform, status,
    displayName: platform, backfillProgress: 1, createdAt: new Date().toISOString(),
  };
}

/** Stub Unipile's GET /api/v1/accounts with the given items (or a failure). */
function stubAccounts(items: unknown[] | "fail"): ReturnType<typeof vi.fn> {
  const fn = vi.fn(async () => items === "fail"
    ? new Response("boom", { status: 500 })
    : new Response(JSON.stringify({ items }), { status: 200, headers: { "content-type": "application/json" } }));
  vi.stubGlobal("fetch", fn);
  return fn;
}

beforeEach(() => {
  resetStoreForTests();
  resetAccountsForTests();
  resetLivenessForTests();
  process.env.UNIPILE_DSN = "https://unipile.test";
  process.env.UNIPILE_API_KEY = "k";
});
afterEach(() => {
  delete process.env.UNIPILE_DSN;
  delete process.env.UNIPILE_API_KEY;
  vi.unstubAllGlobals();
});

describe("accounts verify — liveness", () => {
  it("healthy upstream → stays connected, lastVerifiedAt stamped", async () => {
    const device = getStore().registerDevice();
    getStore().addConnection(connection("acc-li", device.id, "linkedin", "connected"));
    stubAccounts([{ id: "acc-li", type: "LINKEDIN", name: "You", status: "OK" }]);

    const body = await (await accounts(get(device.token))).json();
    expect(body.connections[0].status).toBe("connected");
    expect(body.connections[0].lastVerifiedAt).toBeTruthy();
  });

  it("upstream CREDENTIALS → degraded", async () => {
    const device = getStore().registerDevice();
    getStore().addConnection(connection("acc-li", device.id, "linkedin", "connected"));
    stubAccounts([{ id: "acc-li", type: "LINKEDIN", name: "You", status: "CREDENTIALS" }]);

    const body = await (await accounts(get(device.token))).json();
    expect(body.connections[0].status).toBe("degraded");
  });

  it("account absent upstream → degraded", async () => {
    const device = getStore().registerDevice();
    getStore().addConnection(connection("acc-li", device.id, "linkedin", "connected"));
    stubAccounts([]);

    const body = await (await accounts(get(device.token))).json();
    expect(body.connections[0].status).toBe("degraded");
  });

  it("degraded + healthy upstream → recovers to connected", async () => {
    const device = getStore().registerDevice();
    getStore().addConnection(connection("acc-li", device.id, "linkedin", "degraded"));
    stubAccounts([{ id: "acc-li", type: "LINKEDIN", name: "You", status: "OK" }]);

    const body = await (await accounts(get(device.token))).json();
    expect(body.connections[0].status).toBe("connected");
  });

  it("paused connections are never touched — user intent wins over upstream state", async () => {
    const device = getStore().registerDevice();
    getStore().addConnection(connection("acc-li", device.id, "linkedin", "paused"));
    stubAccounts([{ id: "acc-li", type: "LINKEDIN", name: "You", status: "CREDENTIALS" }]);

    const body = await (await accounts(get(device.token))).json();
    expect(body.connections[0].status).toBe("paused");
    expect(body.connections[0].lastVerifiedAt ?? null).toBeNull();
  });

  it("a Unipile FETCH failure never downgrades anything (no flapping)", async () => {
    const device = getStore().registerDevice();
    getStore().addConnection(connection("acc-li", device.id, "linkedin", "connected"));
    stubAccounts("fail");

    const body = await (await accounts(get(device.token))).json();
    expect(body.connections[0].status).toBe("connected");
  });

  it("TTL: a second verify inside the window skips the upstream call", async () => {
    const device = getStore().registerDevice();
    getStore().addConnection(connection("acc-li", device.id, "linkedin", "connected"));
    const fetchFn = stubAccounts([{ id: "acc-li", type: "LINKEDIN", name: "You", status: "OK" }]);

    await accounts(get(device.token));
    await accounts(get(device.token));
    expect(fetchFn).toHaveBeenCalledTimes(1);
  });

  it("plain GET (no ?verify=1) never calls Unipile; keyless verify is a no-op", async () => {
    const device = getStore().registerDevice();
    getStore().addConnection(connection("acc-li", device.id, "linkedin", "connected"));
    const fetchFn = stubAccounts([]);

    await accounts(get(device.token, false));
    expect(fetchFn).not.toHaveBeenCalled();

    delete process.env.UNIPILE_DSN;    // keyless → mock client → verify no-ops
    delete process.env.UNIPILE_API_KEY;
    const body = await (await accounts(get(device.token))).json();
    expect(fetchFn).not.toHaveBeenCalled();
    expect(body.connections[0].status).toBe("connected");
  });

  it("OAuth-backed platforms (gmail/slack/x) are outside Unipile's authority", async () => {
    const device = getStore().registerDevice();
    getStore().addConnection(connection("c-gmail", device.id, "gmail", "connected"));
    stubAccounts([]);   // gmail is (obviously) not among Unipile accounts

    const body = await (await accounts(get(device.token))).json();
    expect(body.connections[0].status).toBe("connected");
  });
});

describe("accounts — lastSyncAt from the message webhook", () => {
  it("a message_received webhook stamps lastSyncAt; GET /api/accounts returns it", async () => {
    const device = getStore().registerDevice();
    getStore().addConnection(connection("acc-li", device.id, "linkedin", "connected"));

    const res = await unipileWebhook(new Request(`${BASE}/api/webhooks/unipile`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        event: "message_received", account_id: "acc-li", account_type: "LINKEDIN",
        chat_id: "chat-1", message_id: "msg-1", message: "hello",
        sender: { attendee_provider_id: "urn:li:member:5", attendee_name: "Ada" },
        timestamp: new Date().toISOString(),
      }),
    }));
    expect(res.status).toBe(200);

    const body = await (await accounts(get(device.token, false))).json();
    expect(body.connections[0].lastSyncAt).toBeTruthy();
  });
});
