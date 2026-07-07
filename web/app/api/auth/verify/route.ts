// GET /api/auth/verify?token=... — consumes a magic-link token (single-use,
// 15-minute expiry), finds-or-creates the user (first login = sign-up), opens
// a session cookie tied to that user, and redirects to /account.

import { getAccounts } from "@/lib/accounts/store";
import { sessionSetCookie } from "@/lib/auth/session";

export async function GET(req: Request): Promise<Response> {
  const token = new URL(req.url).searchParams.get("token") ?? "";
  const accounts = getAccounts();
  const email = token ? await accounts.consumeMagicLink(token, Date.now()) : null;
  const origin = process.env.PUBLIC_URL ?? new URL(req.url).origin;

  if (!email) {
    return Response.redirect(`${origin}/login?error=expired`, 303);
  }

  const user = await accounts.findOrCreateUserByEmail(email);   // sign-up on first login
  const session = await accounts.createWebSession(user.id);
  return new Response(null, {
    status: 303,
    headers: { Location: `${origin}/account`, "Set-Cookie": sessionSetCookie(session.token) },
  });
}
