// Web login session — a browser cookie, separate from the Mac app's
// device-token auth (lib/connections/auth.ts). Backs the marketing site's
// "Login" flow: email magic link → httpOnly session cookie → /account.
//
// Route handlers get a plain Request/Response, so cookie read/write there is
// manual (Set-Cookie header) — framework-agnostic and testable with plain
// Request objects, no Next.js request-context needed. Server Components
// (the /account page) have no Request object at all, so THAT one spot uses
// `next/headers` cookies(), which only resolves inside a real Next.js
// request — not unit-testable, verified live instead.

import { getAccounts, type AccountUser } from "@/lib/accounts/store";

export const SESSION_COOKIE = "osmo_session";

/** Route-handler side: pull the session token out of an incoming request's
    Cookie header (no framework magic — just a header split). */
export function readSessionToken(req: Request): string | null {
  const raw = req.headers.get("cookie") ?? "";
  for (const part of raw.split(";")) {
    const [k, ...rest] = part.trim().split("=");
    if (k === SESSION_COOKIE) return rest.join("=") || null;
  }
  return null;
}

export function sessionSetCookie(token: string): string {
  const secure = process.env.NODE_ENV === "production" ? "; Secure" : "";
  return `${SESSION_COOKIE}=${token}; Path=/; HttpOnly; SameSite=Lax; Max-Age=${60 * 60 * 24 * 30}${secure}`;
}

export function clearSessionSetCookie(): string {
  return `${SESSION_COOKIE}=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0`;
}

/** Server Component side (e.g. /account): reads the signed-in USER via
    next/headers, which only works inside a real Next.js request. */
export async function currentSessionUser(): Promise<AccountUser | null> {
  const { cookies } = await import("next/headers");
  const jar = await cookies();
  const token = jar.get(SESSION_COOKIE)?.value;
  if (!token) return null;
  return getAccounts().webSessionUser(token);
}
