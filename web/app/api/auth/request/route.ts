// POST /api/auth/request { email } — mints a 15-minute single-use magic link.
//
// The verify URL is a bearer credential: whoever holds it can sign in as `email`.
// So it is delivered by EMAIL and never returned in the response body when a mail
// provider is configured. Only in local dev (no provider, not production) is the
// link returned inline, so the flow stays exercisable before email is wired up.
// In production with no provider we fail CLOSED rather than leak.

import { getAccounts } from "@/lib/accounts/store";
import { sendMagicLink } from "@/lib/email/resend";
import { isProduction } from "@/lib/config/runtime";

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export async function POST(req: Request): Promise<Response> {
  const body = await req.json().catch(() => ({})) as { email?: string };
  const email = typeof body.email === "string" ? body.email.trim().toLowerCase() : "";
  if (!EMAIL_RE.test(email)) {
    return Response.json({ error: "Enter a valid email address." }, { status: 400 });
  }

  const link = await getAccounts().createMagicLink(email, Date.now());
  const origin = process.env.PUBLIC_URL ?? new URL(req.url).origin;
  const verifyUrl = `${origin}/api/auth/verify?token=${link.token}`;

  if (process.env.RESEND_API_KEY) {
    const sent = await sendMagicLink(email, verifyUrl);
    if (!sent) return Response.json({ error: "email_failed" }, { status: 502 });
    // Never leak the link in the body once we can email it.
    return Response.json({ ok: true, mode: "sent" });
  }

  if (isProduction()) {
    // No mail provider in production — do not expose the login token.
    return Response.json({ error: "email_not_configured" }, { status: 500 });
  }

  // Local dev only: surface the link so the login flow is testable.
  return Response.json({ ok: true, mode: "dev", verifyUrl });
}
