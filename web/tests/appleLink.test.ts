// Sign in with Apple — server verifies the identity token; a client-supplied
// appleUserID is never trusted in production.

import crypto from "node:crypto";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { resetStoreForTests } from "@/lib/connections/memoryStore";
import { resetAccountsForTests, getAccounts } from "@/lib/accounts/store";
import { resetAppleJwksCacheForTests } from "@/lib/auth/appleVerify";
import { POST as register } from "@/app/api/device/register/route";
import { POST as link } from "@/app/api/account/link/route";

const CLIENT_ID = "in.leftonread.osmo";
const { publicKey, privateKey } = crypto.generateKeyPairSync("rsa", { modulusLength: 2048 });
const jwk = { ...(publicKey.export({ format: "jwk" }) as Record<string, unknown>), kid: "testkid", alg: "RS256", use: "sig" };

function signJwt(claims: Record<string, unknown>): string {
  const h = Buffer.from(JSON.stringify({ alg: "RS256", kid: "testkid", typ: "JWT" })).toString("base64url");
  const p = Buffer.from(JSON.stringify(claims)).toString("base64url");
  const sig = crypto.sign("RSA-SHA256", Buffer.from(`${h}.${p}`), privateKey).toString("base64url");
  return `${h}.${p}.${sig}`;
}
function appleClaims(over: Record<string, unknown> = {}): Record<string, unknown> {
  const now = Math.floor(Date.now() / 1000);
  return { iss: "https://appleid.apple.com", aud: CLIENT_ID, sub: "apple-sub-123",
    email: "real@icloud.com", email_verified: "true", iat: now, exp: now + 3600, ...over };
}
async function bearer(): Promise<string> {
  return (await (await register()).json()).deviceToken as string;
}
function linkReq(token: string, body: object): Request {
  return new Request("http://localhost:3000/api/account/link", {
    method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: JSON.stringify(body),
  });
}

beforeEach(() => {
  resetStoreForTests(); resetAccountsForTests(); resetAppleJwksCacheForTests();
  process.env.OSMO_APPLE_CLIENT_ID = CLIENT_ID;
  vi.stubGlobal("fetch", vi.fn(async () =>
    new Response(JSON.stringify({ keys: [jwk] }), { status: 200, headers: { "content-type": "application/json" } })));
});
afterEach(() => { delete process.env.OSMO_APPLE_CLIENT_ID; delete process.env.OSMO_ENV; vi.unstubAllGlobals(); });

describe("account/link Apple verification", () => {
  it("accepts a validly-signed identity token and uses its sub as the Apple id", async () => {
    const res = await link(linkReq(await bearer(), { identityToken: signJwt(appleClaims()) }));
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.user.email).toBe("real@icloud.com");
    // The account is keyed to the token's sub, not anything client-supplied.
    const u = await getAccounts().findOrCreateUserByApple("apple-sub-123", null, null);
    expect(u?.email).toBe("real@icloud.com");
  });

  it("rejects a token signed by the wrong key (tamper/forgery)", async () => {
    const other = crypto.generateKeyPairSync("rsa", { modulusLength: 2048 }).privateKey;
    const c = appleClaims();
    const h = Buffer.from(JSON.stringify({ alg: "RS256", kid: "testkid", typ: "JWT" })).toString("base64url");
    const p = Buffer.from(JSON.stringify(c)).toString("base64url");
    const sig = crypto.sign("RSA-SHA256", Buffer.from(`${h}.${p}`), other).toString("base64url");
    const res = await link(linkReq(await bearer(), { identityToken: `${h}.${p}.${sig}` }));
    expect(res.status).toBe(401);
  });

  it("rejects a token for the wrong audience", async () => {
    const res = await link(linkReq(await bearer(), { identityToken: signJwt(appleClaims({ aud: "com.evil.app" })) }));
    expect(res.status).toBe(401);
  });

  it("production rejects a bare appleUserID with no token (the takeover path)", async () => {
    process.env.OSMO_ENV = "production";
    const res = await link(linkReq(await bearer(), { appleUserID: "victim.apple.id", email: "victim@x.com" }));
    expect(res.status).toBe(401);
  });
});
