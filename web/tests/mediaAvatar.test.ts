// W4 — the avatar proxy mode of /api/media. The Mac app can't GET LinkedIn/
// Instagram signed CDN URLs directly (403 unauthenticated), so avatars for
// non-connections never loaded; the proxy fetches them server-side, behind
// device auth + an SSRF host allowlist.

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { getStore, resetStoreForTests } from "@/lib/connections/memoryStore";
import { resetAccountsForTests } from "@/lib/accounts/store";
import { GET as media } from "@/app/api/media/route";

const BASE = "http://localhost:3000";
function get(qs: string, token: string): Request {
  return new Request(`${BASE}/api/media?${qs}`, { headers: { authorization: `Bearer ${token}` } });
}

beforeEach(() => { resetStoreForTests(); resetAccountsForTests(); });
afterEach(() => { vi.unstubAllGlobals(); });

describe("media avatar proxy", () => {
  it("fetches an allowlisted CDN avatar server-side and returns the bytes", async () => {
    const device = getStore().registerDevice();
    const jpeg = new Uint8Array([0xff, 0xd8, 0xff, 0xe0]);
    vi.stubGlobal("fetch", vi.fn(async () => new Response(jpeg, {
      status: 200, headers: { "content-type": "image/jpeg" },
    })));
    const res = await media(get("mode=avatar&url=" + encodeURIComponent("https://media.licdn.com/x/abc.jpg"), device.token));
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("image/jpeg");
    expect(new Uint8Array(await res.arrayBuffer())).toEqual(jpeg);
  });

  it("refuses a non-allowlisted host (SSRF guard) with 400 — never fetches it", async () => {
    const device = getStore().registerDevice();
    const spy = vi.fn(async () => new Response("x"));
    vi.stubGlobal("fetch", spy);
    const res = await media(get("mode=avatar&url=" + encodeURIComponent("https://evil.example.com/x.jpg"), device.token));
    expect(res.status).toBe(400);
    expect(spy).not.toHaveBeenCalled();
  });

  it("refuses a non-https url", async () => {
    const device = getStore().registerDevice();
    const res = await media(get("mode=avatar&url=" + encodeURIComponent("http://media.licdn.com/x.jpg"), device.token));
    expect(res.status).toBe(400);
  });

  it("missing url → 400", async () => {
    const device = getStore().registerDevice();
    const res = await media(get("mode=avatar", device.token));
    expect(res.status).toBe(400);
  });

  it("an upstream miss falls back to the placeholder PNG, not an error", async () => {
    const device = getStore().registerDevice();
    vi.stubGlobal("fetch", vi.fn(async () => new Response("nope", { status: 404 })));
    const res = await media(get("mode=avatar&url=" + encodeURIComponent("https://pbs.twimg.com/x_400x400.jpg"), device.token));
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("image/png");   // placeholder
  });

  it("a redirect to a NON-allowlisted host is rejected (no SSRF via 302)", async () => {
    const device = getStore().registerDevice();
    // First hop: allowlisted CDN 302s to an internal metadata endpoint.
    vi.stubGlobal("fetch", vi.fn(async () => new Response(null, {
      status: 302, headers: { location: "https://169.254.169.254/latest/meta-data/" },
    })));
    const res = await media(get("mode=avatar&url=" + encodeURIComponent("https://media.licdn.com/x.jpg"), device.token));
    expect(res.status).toBe(400);   // untrusted redirect, never followed to the internal host
  });

  it("a redirect to another ALLOWLISTED host is followed once", async () => {
    const device = getStore().registerDevice();
    const jpeg = new Uint8Array([0xff, 0xd8]);
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(new Response(null, { status: 302, headers: { location: "https://pbs.twimg.com/real_400x400.jpg" } }))
      .mockResolvedValueOnce(new Response(jpeg, { status: 200, headers: { "content-type": "image/jpeg" } }));
    vi.stubGlobal("fetch", fetchMock);
    const res = await media(get("mode=avatar&url=" + encodeURIComponent("https://media.licdn.com/x.jpg"), device.token));
    expect(res.status).toBe(200);
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it("an over-cap content-length is rejected BEFORE buffering (413)", async () => {
    const device = getStore().registerDevice();
    vi.stubGlobal("fetch", vi.fn(async () => new Response(new Uint8Array([1]), {
      status: 200, headers: { "content-type": "image/jpeg", "content-length": String(9_000_000) },
    })));
    const res = await media(get("mode=avatar&url=" + encodeURIComponent("https://media.licdn.com/big.jpg"), device.token));
    expect(res.status).toBe(413);
  });
});
