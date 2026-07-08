// POST /api/auth/logout — clears the web session cookie.

import { getAccounts } from "@/lib/accounts/store";
import { readSessionToken, clearSessionSetCookie } from "@/lib/auth/session";
import { sameOrigin, forbidden } from "@/lib/auth/csrf";

export async function POST(req: Request): Promise<Response> {
  if (!sameOrigin(req)) return forbidden();
  const token = readSessionToken(req);
  if (token) await getAccounts().deleteWebSession(token);
  return new Response(JSON.stringify({ ok: true }), {
    headers: { "content-type": "application/json", "Set-Cookie": clearSessionSetCookie() },
  });
}
