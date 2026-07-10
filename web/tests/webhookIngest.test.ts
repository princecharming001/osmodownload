// /api/webhooks/unipile ingestion hardening: every malformed/unknown/replayed
// delivery must be ACKNOWLEDGED (2xx) — Unipile retry-storms on 5xx — while
// only well-formed events for a known connection mutate state. Plus the
// redeploy gap: a webhook that lands before any device call rehydrates the
// in-memory store must still ingest via the durable connection record.

import { beforeEach, afterEach, describe, expect, it } from "vitest";
import { getStore, resetStoreForTests } from "@/lib/connections/memoryStore";
import { resetAccountsForTests } from "@/lib/accounts/store";
import { resetEventsForTests } from "@/lib/connections/events";
import { POST as register } from "@/app/api/device/register/route";
import { POST as connectLink } from "@/app/api/connect/link/route";
import { POST as mockComplete } from "@/app/api/connect/mock/complete/route";
import { GET as accounts } from "@/app/api/accounts/route";
import { GET as pull } from "@/app/api/sync/pull/route";
import { POST as webhook } from "@/app/api/webhooks/unipile/route";

const BASE = "http://localhost:3000";

function req(path: string, token?: string, body?: object): Request {
  return new Request(`${BASE}${path}`, {
    method: body ? "POST" : "GET",
    headers: { ...(body ? { "content-type": "application/json" } : {}), ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
}

function hook(body: string, headers?: Record<string, string>): Request {
  return new Request(`${BASE}/api/webhooks/unipile`, {
    method: "POST", headers: { "content-type": "application/json", ...headers }, body,
  });
}

/** Register a device + complete a mock LinkedIn connect; returns ids. */
async function connected(): Promise<{ token: string; connId: string }> {
  const token = (await (await register()).json()).deviceToken as string;
  const link = await (await connectLink(req("/api/connect/link", token, { platform: "linkedin" }))).json();
  await mockComplete(req("/api/connect/mock/complete", undefined, { linkId: link.linkId }));
  const conn = (await (await accounts(req("/api/accounts", token))).json()).connections[0];
  return { token, connId: conn.id };
}

function messageEvent(connId: string, messageId: string, text: string): object {
  return {
    event: "message_received", account_id: connId, account_type: "LINKEDIN",
    chat_id: "wh-chat-1", message_id: messageId, message: text,
    sender: { attendee_provider_id: "wh-sender-1", attendee_name: "Web Hook" },
    timestamp: new Date().toISOString(),
  };
}

beforeEach(() => {
  resetStoreForTests(); resetAccountsForTests(); resetEventsForTests();
  process.env.OSMO_MOCK_DRIP_MS = "0";
});
afterEach(() => { delete process.env.OSMO_WEBHOOK_SECRET; });

describe("unipile webhook — happy path + replay", () => {
  it("a message event for a known connection lands in the device oplog", async () => {
    const { token, connId } = await connected();
    const seeded = await (await pull(req("/api/sync/pull?since=0", token))).json();

    const res = await webhook(hook(JSON.stringify(messageEvent(connId, "wh-m1", "hello from webhook"))));
    expect(res.status).toBe(200);

    const fresh = await (await pull(req(`/api/sync/pull?since=${seeded.cursor}`, token))).json();
    expect(fresh.messages.map((m: { text: string }) => m.text)).toContain("hello from webhook");
  });

  it("a replayed delivery of the same event appends nothing new (content dedup)", async () => {
    const { token, connId } = await connected();
    const payload = JSON.stringify(messageEvent(connId, "wh-m2", "delivered twice"));
    await webhook(hook(payload));
    const afterFirst = await (await pull(req("/api/sync/pull?since=0", token))).json();

    expect((await webhook(hook(payload))).status).toBe(200);   // replay still 200s
    const afterSecond = await (await pull(req(`/api/sync/pull?since=${afterFirst.cursor}`, token))).json();
    expect(afterSecond.messages).toHaveLength(0);
    expect(afterSecond.threads).toHaveLength(0);
    expect(afterSecond.contacts).toHaveLength(0);
  });

  it("account.status transitions flip the connection (ERROR → degraded, OK → connected)", async () => {
    const { connId } = await connected();
    await webhook(hook(JSON.stringify({ event: "account.status", account_id: connId, status: "ERROR" })));
    expect(getStore().connectionById(connId)?.status).toBe("degraded");
    await webhook(hook(JSON.stringify({ event: "account.status", account_id: connId, status: "OK" })));
    expect(getStore().connectionById(connId)?.status).toBe("connected");
  });
});

describe("unipile webhook — fail closed, never 5xx", () => {
  it("acknowledges malformed payloads without touching state", async () => {
    const { token } = await connected();
    const before = await (await pull(req("/api/sync/pull?since=0", token))).json();

    for (const body of ["not json {{", "null", '"just a string"', "[]", "5", "{}"]) {
      const res = await webhook(hook(body));
      expect(res.status).toBe(200);
    }
    const after = await (await pull(req(`/api/sync/pull?since=${before.cursor}`, token))).json();
    expect(after.messages).toHaveLength(0);
  });

  it("acknowledges unknown / non-string account ids", async () => {
    await connected();
    expect((await webhook(hook(JSON.stringify(messageEvent("acc-nobody", "m", "x"))))).status).toBe(200);
    expect((await webhook(hook(JSON.stringify({ event: "message_received", account_id: 42 })))).status).toBe(200);
    expect((await webhook(hook(JSON.stringify({ event: "message_received", account_id: { nested: true } })))).status).toBe(200);
  });

  it("ignores message events for a paused connection", async () => {
    const { token, connId } = await connected();
    getStore().setConnectionStatus(connId, "paused");
    const before = await (await pull(req("/api/sync/pull?since=0", token))).json();
    expect((await webhook(hook(JSON.stringify(messageEvent(connId, "wh-m3", "while paused"))))).status).toBe(200);
    const after = await (await pull(req(`/api/sync/pull?since=${before.cursor}`, token))).json();
    expect(after.messages).toHaveLength(0);
  });
});

describe("unipile webhook — shared secret", () => {
  it("rejects a missing/wrong secret with 401, accepts the right header", async () => {
    const { connId } = await connected();
    process.env.OSMO_WEBHOOK_SECRET = "s3cret";
    const payload = JSON.stringify(messageEvent(connId, "wh-m4", "secret checked"));
    expect((await webhook(hook(payload))).status).toBe(401);
    expect((await webhook(hook(payload, { "x-osmo-webhook-secret": "wrong" }))).status).toBe(401);
    expect((await webhook(hook(payload, { "x-osmo-webhook-secret": "s3cret" }))).status).toBe(200);
  });
});

describe("unipile webhook — redeploy rehydration", () => {
  it("a webhook that arrives before any device call still ingests (durable connection lookup)", async () => {
    const { token, connId } = await connected();

    // Simulate a redeploy: in-memory sync store wiped, durable accounts intact.
    resetStoreForTests();

    // The webhook lands FIRST — before /api/accounts rehydrates connections.
    const res = await webhook(hook(JSON.stringify(messageEvent(connId, "wh-m5", "post-redeploy"))));
    expect(res.status).toBe(200);

    // The device's next pull (durable token auth, fresh epoch → cursor reset
    // to 0 client-side) sees the message instead of it being silently dropped.
    const fresh = await (await pull(req("/api/sync/pull?since=0", token))).json();
    expect(fresh.messages.map((m: { text: string }) => m.text)).toContain("post-redeploy");
  });
});
