import { beforeEach, describe, expect, it } from "vitest";
import { resetStoreForTests } from "@/lib/connections/memoryStore";
import { POST as register } from "@/app/api/device/register/route";
import { POST as redeemPromo } from "@/app/api/promo/redeem/route";
import { GET as flags } from "@/app/api/config/flags/route";
import type { EntitlementPayload } from "@/lib/license/sign";

const BASE = "http://localhost:3000";
function req(path: string, token?: string, body?: unknown): Request {
  return new Request(`${BASE}${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}
async function registered(): Promise<string> {
  return (await (await register()).json()).deviceToken;
}
function decode(entitlement: string): EntitlementPayload {
  return JSON.parse(Buffer.from(entitlement, "base64url").toString());
}

beforeEach(() => { resetStoreForTests(); delete process.env.OSMO_FLAGS; });

describe("promo redemption", () => {
  it("a trial code starts/extends the trial", async () => {
    const token = await registered();
    const res = await redeemPromo(req("/api/promo/redeem", token, { code: "FRIEND" }));
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.applied).toBe("trial");
    expect(decode(body.entitlement).tier).toBe("trial");
  });

  it("an unknown code is 404, auth required", async () => {
    const token = await registered();
    expect((await redeemPromo(req("/api/promo/redeem", token, { code: "NOPE" }))).status).toBe(404);
    expect((await redeemPromo(req("/api/promo/redeem", undefined, { code: "FRIEND" }))).status).toBe(401);
  });
});

describe("feature flags", () => {
  it("returns the defaults", async () => {
    const body = await (await flags()).json();
    expect(body.flags.aiDrafting).toBe(true);
    expect(body.flags.autodraft).toBe(true);
  });

  it("OSMO_FLAGS overrides a flag (the remote kill-switch)", async () => {
    process.env.OSMO_FLAGS = JSON.stringify({ aiDrafting: false });
    const body = await (await flags()).json();
    expect(body.flags.aiDrafting).toBe(false);
    expect(body.flags.enrichment).toBe(true);   // untouched defaults remain
  });
});
