// CSRF defense for COOKIE-authed state-changing requests: the request's Origin
// must match our own site. Device/Bearer-token routes are not CSRF-vulnerable (an
// attacker page can't read the token), so this applies only to the cookie POSTs
// (logout, account/upgrade). SameSite=Lax already blocks most cross-site POSTs;
// this is the explicit backstop.

export function sameOrigin(req: Request): boolean {
  const origin = req.headers.get("origin");
  if (!origin) return false; // a state-changing cookie POST must send Origin
  const allowed = new Set<string>();
  try { allowed.add(new URL(req.url).origin); } catch { /* ignore */ }
  if (process.env.PUBLIC_URL) { try { allowed.add(new URL(process.env.PUBLIC_URL).origin); } catch { /* ignore */ } }
  try { return allowed.has(new URL(origin).origin); } catch { return false; }
}

export function forbidden(): Response {
  return Response.json({ error: "forbidden" }, { status: 403 });
}
