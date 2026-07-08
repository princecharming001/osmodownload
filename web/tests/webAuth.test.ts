// Web login/signup — the accounts store (magic links + users + web sessions)
// and the request/verify/logout route handlers. Runs against the in-memory
// AccountsStore (no SUPABASE_* env in tests). Server-Component session reads
// (next/headers) are verified live in the browser preview, not here.

import { beforeEach, describe, expect, it } from "vitest";
import { getAccounts, resetAccountsForTests } from "@/lib/accounts/store";
import { POST as authRequest } from "@/app/api/auth/request/route";
import { GET as authVerify } from "@/app/api/auth/verify/route";
import { POST as authLogout } from "@/app/api/auth/logout/route";
import { SESSION_COOKIE, readSessionToken } from "@/lib/auth/session";

const BASE = "http://localhost:3000";

function jreq(path: string, body?: unknown): Request {
  return new Request(`${BASE}${path}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

function extractCookie(res: Response): string {
  const setCookie = res.headers.get("set-cookie") ?? "";
  const match = setCookie.match(new RegExp(`${SESSION_COOKIE}=([^;]*)`));
  return match?.[1] ?? "";
}

describe("accounts store — magic links, users, web sessions", () => {
  beforeEach(() => resetAccountsForTests());

  it("a magic link is single-use", async () => {
    const a = getAccounts();
    const link = await a.createMagicLink("a@b.com", 1000);
    expect(await a.consumeMagicLink(link.token, 1500)).toBe("a@b.com");
    expect(await a.consumeMagicLink(link.token, 1500)).toBeNull(); // already used
  });

  it("a magic link expires after 15 minutes", async () => {
    const a = getAccounts();
    const link = await a.createMagicLink("a@b.com", 1000);
    expect(await a.consumeMagicLink(link.token, 1000 + 16 * 60_000)).toBeNull();
  });

  it("an unknown token consumes to null", async () => {
    expect(await getAccounts().consumeMagicLink("nope", Date.now())).toBeNull();
  });

  it("first login creates the user; second login reuses it", async () => {
    const a = getAccounts();
    const u1 = await a.findOrCreateUserByEmail("A@B.com");
    const u2 = await a.findOrCreateUserByEmail("a@b.com"); // case-insensitive
    expect(u1.id).toBe(u2.id);
    expect(u1.email).toBe("a@b.com");
  });

  it("web sessions resolve to their user and can be revoked", async () => {
    const a = getAccounts();
    const user = await a.findOrCreateUserByEmail("a@b.com");
    const session = await a.createWebSession(user.id);
    expect((await a.webSessionUser(session.token))?.email).toBe("a@b.com");
    await a.deleteWebSession(session.token);
    expect(await a.webSessionUser(session.token)).toBeNull();
  });
});

describe("auth routes", () => {
  beforeEach(() => resetAccountsForTests());

  it("rejects a malformed email", async () => {
    const res = await authRequest(jreq("/api/auth/request", { email: "not-an-email" }));
    expect(res.status).toBe(400);
  });

  it("dev mode (no provider, not prod) returns the verify URL directly for local testing", async () => {
    const res = await authRequest(jreq("/api/auth/request", { email: "a@b.com" }));
    const body = await res.json();
    expect(body.mode).toBe("dev");
    expect(body.verifyUrl).toContain("/api/auth/verify?token=");
  });

  it("verify signs the user up, sets a session cookie, redirects to /account", async () => {
    const requestRes = await authRequest(jreq("/api/auth/request", { email: "a@b.com" }));
    const { verifyUrl } = await requestRes.json();

    const verifyRes = await authVerify(new Request(verifyUrl));
    expect(verifyRes.status).toBe(303);
    expect(verifyRes.headers.get("location")).toContain("/account");

    const token = extractCookie(verifyRes);
    expect(token).not.toBe("");
    expect((await getAccounts().webSessionUser(token))?.email).toBe("a@b.com");
  });

  it("verify rejects a reused or unknown token", async () => {
    const requestRes = await authRequest(jreq("/api/auth/request", { email: "a@b.com" }));
    const { verifyUrl } = await requestRes.json();

    await authVerify(new Request(verifyUrl));                 // first use — succeeds
    const second = await authVerify(new Request(verifyUrl));  // second use — rejected
    expect(second.headers.get("location")).toContain("/login?error=expired");
  });

  it("logout deletes the session and clears the cookie", async () => {
    const requestRes = await authRequest(jreq("/api/auth/request", { email: "a@b.com" }));
    const { verifyUrl } = await requestRes.json();
    const verifyRes = await authVerify(new Request(verifyUrl));
    const token = extractCookie(verifyRes);

    const logoutReq = new Request(`${BASE}/api/auth/logout`, {
      method: "POST", headers: { cookie: `${SESSION_COOKIE}=${token}` },
    });
    expect(readSessionToken(logoutReq)).toBe(token);

    const logoutRes = await authLogout(logoutReq);
    expect((await logoutRes.json()).ok).toBe(true);
    expect(await getAccounts().webSessionUser(token)).toBeNull();
  });
});
