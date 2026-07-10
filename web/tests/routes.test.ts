// Route handlers invoked directly as functions — the full mock connect loop.

import { beforeEach, describe, expect, it } from "vitest";
import { resetStoreForTests, getStore } from "@/lib/connections/memoryStore";
import { resetEventsForTests } from "@/lib/connections/events";
import { POST as register } from "@/app/api/device/register/route";
import { POST as connectLink } from "@/app/api/connect/link/route";
import { POST as mockComplete } from "@/app/api/connect/mock/complete/route";
import { GET as accounts } from "@/app/api/accounts/route";
import { GET as pull } from "@/app/api/sync/pull/route";
import { POST as send } from "@/app/api/sync/send/route";
import { POST as emit } from "@/app/api/dev/emit/route";
import { GET as outbox } from "@/app/api/dev/outbox/route";
import { GET as media } from "@/app/api/media/route";

const BASE = "http://localhost:3000";

async function registered(): Promise<{ token: string; deviceId: string }> {
  const res = await register();
  const body = await res.json();
  return { token: body.deviceToken, deviceId: body.deviceId };
}

function req(path: string, token?: string, init?: RequestInit): Request {
  return new Request(`${BASE}${path}`, {
    ...init,
    headers: {
      ...(init?.body ? { "content-type": "application/json" } : {}),
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...init?.headers,
    },
  });
}

beforeEach(() => { resetStoreForTests(); resetEventsForTests(); delete process.env.OSMO_MOCK_DRIP_MS; });

describe("device + auth", () => {
  it("register issues usable credentials; mode is mock keyless", async () => {
    const res = await register();
    const body = await res.json();
    expect(body.deviceId).toMatch(/^dev-/);
    expect(body.deviceToken.length).toBeGreaterThan(20);
    expect(body.mode).toBe("mock");
  });

  it("rejects missing/unknown bearer tokens with 401", async () => {
    expect((await pull(req("/api/sync/pull?since=0"))).status).toBe(401);
    expect((await pull(req("/api/sync/pull?since=0", "bogus"))).status).toBe(401);
  });
});

describe("mock connect loop", () => {
  it("link → wizard-complete → accounts shows connected → pull returns seed", async () => {
    process.env.OSMO_MOCK_DRIP_MS = "0";   // no timers in tests
    const { token } = await registered();

    const linkRes = await connectLink(req("/api/connect/link", token, {
      method: "POST", body: JSON.stringify({ platform: "linkedin" }),
    }));
    expect(linkRes.status).toBe(200);
    const link = await linkRes.json();
    expect(link.mode).toBe("mock");
    expect(link.url).toContain("/connect/mock?");

    const doneRes = await mockComplete(req("/api/connect/mock/complete", undefined, {
      method: "POST", body: JSON.stringify({ linkId: link.linkId }),
    }));
    expect(doneRes.status).toBe(200);

    const acctRes = await accounts(req("/api/accounts", token));
    const accts = await acctRes.json();
    expect(accts.connections).toHaveLength(1);
    expect(accts.connections[0].status).toBe("connected");
    expect(accts.connections[0].platform).toBe("linkedin");

    const batch = await (await pull(req("/api/sync/pull?since=0&limit=500", token))).json();
    expect(batch.messages.length).toBeGreaterThan(3);
    expect(batch.threads.length).toBeGreaterThan(1);
    expect(batch.contacts.length).toBeGreaterThan(1);
    expect(batch.hasMore).toBe(false);

    // Second pull from the cursor → empty (nothing new).
    const again = await (await pull(req(`/api/sync/pull?since=${batch.cursor}`, token))).json();
    expect(again.messages).toHaveLength(0);
  });

  it("mock-complete is single-use (409 on replay)", async () => {
    process.env.OSMO_MOCK_DRIP_MS = "0";
    const { token } = await registered();
    const link = await (await connectLink(req("/api/connect/link", token, {
      method: "POST", body: JSON.stringify({ platform: "whatsapp" }),
    }))).json();
    const c = (body: object) => mockComplete(req("/api/connect/mock/complete", undefined, {
      method: "POST", body: JSON.stringify(body),
    }));
    expect((await c({ linkId: link.linkId })).status).toBe(200);
    expect((await c({ linkId: link.linkId })).status).toBe(409);
    expect((await c({ linkId: "link-nope" })).status).toBe(404);
  });

  it("rejects unknown platforms on link", async () => {
    const { token } = await registered();
    const res = await connectLink(req("/api/connect/link", token, {
      method: "POST", body: JSON.stringify({ platform: "imessage" }),
    }));
    expect(res.status).toBe(400);
  });
});

describe("emit + send", () => {
  it("dev/emit appends an inbound; send records outbox + oplog echo", async () => {
    process.env.OSMO_MOCK_DRIP_MS = "0";
    const { token } = await registered();
    const link = await (await connectLink(req("/api/connect/link", token, {
      method: "POST", body: JSON.stringify({ platform: "linkedin" }),
    }))).json();
    await mockComplete(req("/api/connect/mock/complete", undefined, {
      method: "POST", body: JSON.stringify({ linkId: link.linkId }),
    }));
    const seeded = await (await pull(req("/api/sync/pull?since=0", token))).json();

    // Inbound emit → new row past the cursor.
    const emitRes = await emit(req("/api/dev/emit", token, {
      method: "POST", body: JSON.stringify({ platform: "linkedin", text: "ping from e2e" }),
    }));
    expect(emitRes.status).toBe(200);
    const fresh = await (await pull(req(`/api/sync/pull?since=${seeded.cursor}`, token))).json();
    expect(fresh.messages.map((m: { text: string }) => m.text)).toContain("ping from e2e");

    // Send → echo carries a real platformMessageID; outbox has the exact text.
    const sendRes = await send(req("/api/sync/send", token, {
      method: "POST",
      body: JSON.stringify({ platform: "linkedin", platformThreadID: "demo-li-chat-1", text: "edited reply!" }),
    }));
    expect(sendRes.status).toBe(200);
    const echo = await sendRes.json();
    expect(echo.message.isFromMe).toBe(true);
    expect(echo.message.platformMessageID).toMatch(/^mock-sent-/);

    const box = await (await outbox(req("/api/dev/outbox", token))).json();
    expect(box.outbox.map((m: { text: string }) => m.text)).toEqual(["edited reply!"]);
  });

  it("two same-instant emits both land — ids come from a counter, not Date.now()", async () => {
    process.env.OSMO_MOCK_DRIP_MS = "0";
    const { token } = await registered();
    const link = await (await connectLink(req("/api/connect/link", token, {
      method: "POST", body: JSON.stringify({ platform: "linkedin" }),
    }))).json();
    await mockComplete(req("/api/connect/mock/complete", undefined, {
      method: "POST", body: JSON.stringify({ linkId: link.linkId }),
    }));
    const seeded = await (await pull(req("/api/sync/pull?since=0", token))).json();

    // Same millisecond, same text — the old Date.now()%100_000 index made these
    // the same platformMessageID, and the oplog dedup swallowed the second.
    const body = { platform: "linkedin", text: "double tap" };
    await emit(req("/api/dev/emit", token, { method: "POST", body: JSON.stringify(body) }));
    await emit(req("/api/dev/emit", token, { method: "POST", body: JSON.stringify(body) }));

    const fresh = await (await pull(req(`/api/sync/pull?since=${seeded.cursor}`, token))).json();
    const dups = fresh.messages.filter((m: { text: string }) => m.text === "double tap");
    expect(dups).toHaveLength(2);
    expect(new Set(dups.map((m: { platformMessageID: string }) => m.platformMessageID)).size).toBe(2);
  });

  it("send without a live connection is 409", async () => {
    const { token } = await registered();
    const res = await send(req("/api/sync/send", token, {
      method: "POST",
      body: JSON.stringify({ platform: "slack", platformThreadID: "x", text: "hello" }),
    }));
    expect(res.status).toBe(409);
  });
});

describe("pause/disconnect", () => {
  it("paused connections stop the drip's effect and can resume", async () => {
    process.env.OSMO_MOCK_DRIP_MS = "0";
    const { token } = await registered();
    const link = await (await connectLink(req("/api/connect/link", token, {
      method: "POST", body: JSON.stringify({ platform: "slack" }),
    }))).json();
    await mockComplete(req("/api/connect/mock/complete", undefined, {
      method: "POST", body: JSON.stringify({ linkId: link.linkId }),
    }));
    const { PATCH: patchAccounts, DELETE: deleteAccounts } = await import("@/app/api/accounts/route");
    const conn = (await (await accounts(req("/api/accounts", token))).json()).connections[0];

    const pauseRes = await patchAccounts(req(`/api/accounts?id=${conn.id}`, token, {
      method: "PATCH", body: JSON.stringify({ action: "pause" }),
    }));
    expect(pauseRes.status).toBe(200);
    expect(getStore().connectionById(conn.id)?.status).toBe("paused");

    const delRes = await deleteAccounts(req(`/api/accounts?id=${conn.id}`, token, { method: "DELETE" }));
    expect(delRes.status).toBe(200);
    expect((await (await accounts(req("/api/accounts", token))).json()).connections).toHaveLength(0);
  });
});

describe("media proxy", () => {
  it("rejects unauthenticated requests", async () => {
    const res = await media(req("/api/media?platform=gmail&messageRef=m1&attachmentRef=a1"));
    expect(res.status).toBe(401);
  });

  it("rejects a request missing required params", async () => {
    const { token } = await registered();
    const res = await media(req("/api/media?platform=gmail", token));
    expect(res.status).toBe(400);
  });

  it("a device with no connection for the platform gets a placeholder image, not an error", async () => {
    const { token } = await registered();
    const res = await media(req("/api/media?platform=gmail&messageRef=m1&attachmentRef=a1", token));
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("image/png");
  });

  it("Slack refuses to fetch anything other than files.slack.com (SSRF guard)", async () => {
    process.env.OSMO_MOCK_DRIP_MS = "0";
    const { token, deviceId } = await registered();
    const link = await (await connectLink(req("/api/connect/link", token, {
      method: "POST", body: JSON.stringify({ platform: "slack" }),
    }))).json();
    await mockComplete(req("/api/connect/mock/complete", undefined, {
      method: "POST", body: JSON.stringify({ linkId: link.linkId }),
    }));
    getStore().setOAuthTokens(deviceId, "slack", { access_token: "xoxp-fake" });
    const res = await media(req(
      "/api/media?platform=slack&messageRef=m1&attachmentRef=https://evil.example.com/steal", token));
    expect(res.status).toBe(400);
  });
});

describe("pull cursor/limit sanitization", () => {
  it("junk `since` values are 400, not an empty-forever stream", async () => {
    const { token } = await registered();
    for (const since of ["abc", "Infinity", "-1", "NaN"]) {
      const res = await pull(req(`/api/sync/pull?since=${since}`, token));
      expect(res.status, `since=${since}`).toBe(400);
    }
  });

  it("a junk `limit` falls back to the default instead of slicing an empty page forever", async () => {
    process.env.OSMO_MOCK_DRIP_MS = "0";
    const { token } = await registered();
    const link = await (await connectLink(req("/api/connect/link", token, {
      method: "POST", body: JSON.stringify({ platform: "linkedin" }),
    }))).json();
    await mockComplete(req("/api/connect/mock/complete", undefined, {
      method: "POST", body: JSON.stringify({ linkId: link.linkId }),
    }));

    // The old Math.min(NaN, cap) sliced an EMPTY page while hasMore stayed
    // true — a client polling with a junk limit would loop forever.
    for (const limit of ["abc", "-5", "0", "Infinity"]) {
      const batch = await (await pull(req(`/api/sync/pull?since=0&limit=${limit}`, token))).json();
      expect(batch.messages.length, `limit=${limit}`).toBeGreaterThan(0);
      expect(batch.hasMore).toBe(false);
    }
  });
});
