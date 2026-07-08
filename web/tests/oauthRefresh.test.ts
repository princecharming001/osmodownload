// OAuth token refresh — Gmail/X tokens are refreshed on expiry and re-persisted;
// a failed refresh degrades the connection (prompt reconnect).

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { getStore, resetStoreForTests } from "@/lib/connections/memoryStore";
import { freshOAuthToken } from "@/lib/oauth/tokens";
import { POST as register } from "@/app/api/device/register/route";
import { POST as connectLink } from "@/app/api/connect/link/route";
import { POST as mockComplete } from "@/app/api/connect/mock/complete/route";

const BASE = "http://localhost:3000";
function req(path: string, token?: string, body?: object): Request {
  return new Request(`${BASE}${path}`, {
    method: "POST",
    headers: { ...(body ? { "content-type": "application/json" } : {}), ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
}

beforeEach(() => { resetStoreForTests(); process.env.OSMO_MOCK_DRIP_MS = "0"; });
afterEach(() => vi.unstubAllGlobals());

describe("oauth token refresh", () => {
  it("refreshes an expired token and re-persists the new bundle", async () => {
    const dev = "dev-x";
    getStore().setOAuthTokens(dev, "x", { access_token: "old", refresh_token: "r1", expires_in: 3600, obtained_at: Date.now() - 4_000_000 });
    vi.stubGlobal("fetch", vi.fn(async () =>
      new Response(JSON.stringify({ access_token: "new-x", expires_in: 7200 }), { status: 200, headers: { "content-type": "application/json" } })));
    const bundle = await freshOAuthToken(dev, "x");
    expect(bundle.access_token).toBe("new-x");
    expect((getStore().oauthTokens(dev, "x") as { access_token: string }).access_token).toBe("new-x");
  });

  it("does not refresh a still-valid token", async () => {
    const dev = "dev-x2";
    getStore().setOAuthTokens(dev, "x", { access_token: "good", refresh_token: "r", expires_in: 3600, obtained_at: Date.now() });
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);
    expect((await freshOAuthToken(dev, "x")).access_token).toBe("good");
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("degrades the connection when refresh fails", async () => {
    const token = (await (await register()).json()).deviceToken as string;
    const deviceId = getStore().deviceByToken(token)!.id;
    const link = await (await connectLink(req("/api/connect/link", token, { platform: "x" }))).json();
    await mockComplete(req("/api/connect/mock/complete", undefined, { linkId: link.linkId }));

    getStore().setOAuthTokens(deviceId, "x", { access_token: "old", refresh_token: "r1", expires_in: 1, obtained_at: Date.now() - 10_000 });
    vi.stubGlobal("fetch", vi.fn(async () => new Response("nope", { status: 400 })));
    await freshOAuthToken(deviceId, "x");
    const conn = getStore().connections(deviceId).find((c) => c.platform === "x");
    expect(conn?.status).toBe("degraded");
  });
});
