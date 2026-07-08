// 0-B: connection records survive a redeploy (rehydrated from osmo_connections).
// Also exercises the durable device-token fallback end-to-end via /api/accounts.

import { beforeEach, describe, expect, it } from "vitest";
import { resetStoreForTests, getStore } from "@/lib/connections/memoryStore";
import { resetAccountsForTests } from "@/lib/accounts/store";
import { resetEventsForTests } from "@/lib/connections/events";
import { POST as register } from "@/app/api/device/register/route";
import { POST as connectLink } from "@/app/api/connect/link/route";
import { POST as mockComplete } from "@/app/api/connect/mock/complete/route";
import { GET as accounts, PATCH as patchAccounts } from "@/app/api/accounts/route";
import { POST as send } from "@/app/api/sync/send/route";

const BASE = "http://localhost:3000";
function req(path: string, token?: string, body?: object): Request {
  return new Request(`${BASE}${path}`, {
    method: body ? "POST" : "GET",
    headers: { ...(body ? { "content-type": "application/json" } : {}), ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
}

beforeEach(() => { resetStoreForTests(); resetAccountsForTests(); resetEventsForTests(); process.env.OSMO_MOCK_DRIP_MS = "0"; });

describe("connection durability", () => {
  it("connections + device token survive a redeploy (durable rehydrate)", async () => {
    const token = (await (await register()).json()).deviceToken as string;
    const link = await (await connectLink(req("/api/connect/link", token, { platform: "linkedin" }))).json();
    await mockComplete(req("/api/connect/mock/complete", undefined, { linkId: link.linkId }));
    expect((await (await accounts(req("/api/accounts", token))).json()).connections).toHaveLength(1);

    // Simulate a redeploy: wipe ONLY the in-memory sync store; the durable
    // accounts store (device token + connection record) is intact.
    resetStoreForTests();
    expect(getStore().connections("").length).toBe(0); // memory really is empty

    const res = await accounts(req("/api/accounts", token)); // durable device auth + connection rehydrate
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.connections).toHaveLength(1);
    expect(body.connections[0].platform).toBe("linkedin");
    expect(body.connections[0].status).toBe("connected");
  });

  it("send + pause work after a redeploy without a prior /api/accounts warm-up", async () => {
    const token = (await (await register()).json()).deviceToken as string;
    const link = await (await connectLink(req("/api/connect/link", token, { platform: "linkedin" }))).json();
    await mockComplete(req("/api/connect/mock/complete", undefined, { linkId: link.linkId }));
    const conn = (await (await accounts(req("/api/accounts", token))).json()).connections[0];

    // Redeploy, then hit a WRITE path directly (no GET first) — must rehydrate.
    resetStoreForTests();
    const sendRes = await send(req("/api/sync/send", token, {
      platform: "linkedin", platformThreadID: "demo-li-chat-1", text: "hi",
    }));
    expect(sendRes.status).toBe(200); // not 409 "no live connection"

    resetStoreForTests();
    const patchRes = await patchAccounts(new Request(`${BASE}/api/accounts?id=${conn.id}`, {
      method: "PATCH", headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
      body: JSON.stringify({ action: "pause" }),
    }));
    expect(patchRes.status).toBe(200); // not 404 "unknown connection"
  });
});
