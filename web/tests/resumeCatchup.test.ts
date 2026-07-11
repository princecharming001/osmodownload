// Resuming a paused connection must catch up on what the pause silently
// dropped: the Unipile webhook handler hard-drops inbound messages for a
// paused connection (unipile/route.ts) rather than buffering them, so resume
// has to actively pull instead of waiting for the next incidental message.

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { getStore, resetStoreForTests } from "@/lib/connections/memoryStore";
import { resetAccountsForTests } from "@/lib/accounts/store";
import { backfillConnection } from "@/lib/connections/backfill";
import { backfillSlack } from "@/lib/oauth/slackBackfill";
import { backfillGmail } from "@/lib/oauth/gmailBackfill";
import { backfillX } from "@/lib/oauth/xBackfill";

vi.mock("@/lib/connections/backfill", () => ({ backfillConnection: vi.fn(async () => {}) }));
vi.mock("@/lib/oauth/slackBackfill", () => ({ backfillSlack: vi.fn(async () => {}) }));
vi.mock("@/lib/oauth/gmailBackfill", () => ({ backfillGmail: vi.fn(async () => {}) }));
vi.mock("@/lib/oauth/xBackfill", () => ({ backfillX: vi.fn(async () => {}) }));

const BASE = "http://localhost:3000";
function req(path: string, token?: string, init?: RequestInit): Request {
  return new Request(`${BASE}${path}`, {
    ...init,
    headers: { ...(init?.body ? { "content-type": "application/json" } : {}),
              ...(token ? { authorization: `Bearer ${token}` } : {}) },
  });
}
/** Let the route's fire-and-forget resync land. */
const tick = () => new Promise((r) => setTimeout(r, 0));

beforeEach(() => { resetStoreForTests(); resetAccountsForTests(); vi.clearAllMocks(); });
afterEach(() => { delete process.env.SLACK_CLIENT_ID; delete process.env.SLACK_CLIENT_SECRET; });

describe("resume triggers a catch-up resync", () => {
  it("resuming a keyless/mock connection fires the Unipile catch-up path", async () => {
    const { POST: register } = await import("@/app/api/device/register/route");
    const { POST: connectLink } = await import("@/app/api/connect/link/route");
    const { POST: mockComplete } = await import("@/app/api/connect/mock/complete/route");
    const { PATCH: patchAccounts } = await import("@/app/api/accounts/route");

    const token = (await (await register()).json()).deviceToken as string;
    const link = await (await connectLink(req("/api/connect/link", token, {
      method: "POST", body: JSON.stringify({ platform: "linkedin" }),
    }))).json();
    await mockComplete(req("/api/connect/mock/complete", undefined, {
      method: "POST", body: JSON.stringify({ linkId: link.linkId }),
    }));
    const conn = getStore().connections(getStore().deviceByToken(token)!.id)[0];

    await patchAccounts(req(`/api/accounts?id=${conn.id}`, token, {
      method: "PATCH", body: JSON.stringify({ action: "pause" }),
    }));
    vi.clearAllMocks();   // discount anything the initial connect/backfill triggered

    const resumeRes = await patchAccounts(req(`/api/accounts?id=${conn.id}`, token, {
      method: "PATCH", body: JSON.stringify({ action: "resume" }),
    }));
    expect(resumeRes.status).toBe(200);
    await tick();
    expect(backfillConnection).toHaveBeenCalledTimes(1);
  });

  it("resuming a live-OAuth slack connection with stored tokens fires the Slack catch-up path", async () => {
    process.env.SLACK_CLIENT_ID = "id"; process.env.SLACK_CLIENT_SECRET = "secret";
    const { POST: register } = await import("@/app/api/device/register/route");
    const { PATCH: patchAccounts } = await import("@/app/api/accounts/route");

    const token = (await (await register()).json()).deviceToken as string;
    const store = getStore();
    const deviceId = store.deviceByToken(token)!.id;
    store.setOAuthTokens(deviceId, "slack", { authed_user: { access_token: "xoxp-1", id: "U1" }, team: { id: "T1" } });
    const conn = { id: "slack-1", deviceId, platform: "slack" as const, status: "paused" as const,
                   displayName: "Slack", backfillProgress: 1, createdAt: new Date().toISOString(),
                   lastSyncAt: new Date().toISOString() };
    store.hydrateConnection(conn);

    const resumeRes = await patchAccounts(req(`/api/accounts?id=${conn.id}`, token, {
      method: "PATCH", body: JSON.stringify({ action: "resume" }),
    }));
    expect(resumeRes.status).toBe(200);
    await tick();
    expect(backfillSlack).toHaveBeenCalledWith(deviceId, conn.id, "xoxp-1", "U1", "T1");
  });

  it("resuming a live-OAuth gmail connection with a stored token fires the Gmail catch-up path", async () => {
    process.env.GOOGLE_CLIENT_ID = "id"; process.env.GOOGLE_CLIENT_SECRET = "secret";
    const { POST: register } = await import("@/app/api/device/register/route");
    const { PATCH: patchAccounts } = await import("@/app/api/accounts/route");

    const token = (await (await register()).json()).deviceToken as string;
    const store = getStore();
    const deviceId = store.deviceByToken(token)!.id;
    store.setOAuthTokens(deviceId, "gmail", { access_token: "gtok-1" });
    const conn = { id: "gmail-1", deviceId, platform: "gmail" as const, status: "paused" as const,
                   displayName: "Gmail", backfillProgress: 1, createdAt: new Date().toISOString(),
                   lastSyncAt: new Date().toISOString() };
    store.hydrateConnection(conn);

    const resumeRes = await patchAccounts(req(`/api/accounts?id=${conn.id}`, token, {
      method: "PATCH", body: JSON.stringify({ action: "resume" }),
    }));
    expect(resumeRes.status).toBe(200);
    await tick();
    expect(backfillGmail).toHaveBeenCalledWith(deviceId, conn.id, "gtok-1");
    delete process.env.GOOGLE_CLIENT_ID; delete process.env.GOOGLE_CLIENT_SECRET;
  });

  it("resuming a live-OAuth gmail connection with NO stored token 409s and leaves it un-stranded", async () => {
    process.env.GOOGLE_CLIENT_ID = "id"; process.env.GOOGLE_CLIENT_SECRET = "secret";
    const { POST: register } = await import("@/app/api/device/register/route");
    const { PATCH: patchAccounts } = await import("@/app/api/accounts/route");

    const token = (await (await register()).json()).deviceToken as string;
    const store = getStore();
    const deviceId = store.deviceByToken(token)!.id;
    const conn = { id: "gmail-2", deviceId, platform: "gmail" as const, status: "paused" as const,
                   displayName: "Gmail", backfillProgress: 1, createdAt: new Date().toISOString(),
                   lastSyncAt: new Date().toISOString() };
    store.hydrateConnection(conn);

    // The PATCH route fires resyncConnection fire-and-forget and always
    // returns 200 for the pause/resume action itself — the 409 lives inside
    // resyncConnection's own result, not the PATCH response.
    const resumeRes = await patchAccounts(req(`/api/accounts?id=${conn.id}`, token, {
      method: "PATCH", body: JSON.stringify({ action: "resume" }),
    }));
    expect(resumeRes.status).toBe(200);
    await tick();
    expect(backfillGmail).not.toHaveBeenCalled();
    expect(store.connectionById(conn.id)?.status).toBe("connected"); // never stranded in "backfilling"
    delete process.env.GOOGLE_CLIENT_ID; delete process.env.GOOGLE_CLIENT_SECRET;
  });

  it("resuming a live-OAuth x connection with a stored token fires the X catch-up path", async () => {
    const { POST: register } = await import("@/app/api/device/register/route");
    const { PATCH: patchAccounts } = await import("@/app/api/accounts/route");

    const token = (await (await register()).json()).deviceToken as string;
    const store = getStore();
    const deviceId = store.deviceByToken(token)!.id;
    store.setOAuthTokens(deviceId, "x", { access_token: "xtok-1" });
    const conn = { id: "x-1", deviceId, platform: "x" as const, status: "paused" as const,
                   displayName: "X", backfillProgress: 1, createdAt: new Date().toISOString(),
                   lastSyncAt: new Date().toISOString() };
    store.hydrateConnection(conn);

    const resumeRes = await patchAccounts(req(`/api/accounts?id=${conn.id}`, token, {
      method: "PATCH", body: JSON.stringify({ action: "resume" }),
    }));
    expect(resumeRes.status).toBe(200);
    await tick();
    expect(backfillX).toHaveBeenCalledWith(deviceId, conn.id, "xtok-1");
  });

  it("pausing does NOT trigger a resync", async () => {
    const { POST: register } = await import("@/app/api/device/register/route");
    const { POST: connectLink } = await import("@/app/api/connect/link/route");
    const { POST: mockComplete } = await import("@/app/api/connect/mock/complete/route");
    const { PATCH: patchAccounts } = await import("@/app/api/accounts/route");

    const token = (await (await register()).json()).deviceToken as string;
    const link = await (await connectLink(req("/api/connect/link", token, {
      method: "POST", body: JSON.stringify({ platform: "linkedin" }),
    }))).json();
    await mockComplete(req("/api/connect/mock/complete", undefined, {
      method: "POST", body: JSON.stringify({ linkId: link.linkId }),
    }));
    const conn = getStore().connections(getStore().deviceByToken(token)!.id)[0];
    vi.clearAllMocks();

    await patchAccounts(req(`/api/accounts?id=${conn.id}`, token, {
      method: "PATCH", body: JSON.stringify({ action: "pause" }),
    }));
    await tick();
    expect(backfillConnection).not.toHaveBeenCalled();
  });
});
