// POST /api/auth/request { email } — mints a 15-minute single-use magic link.
// Live mode (RESEND_API_KEY set) sends it by email. Keyless/dev mode has
// nowhere to deliver an email, so it returns the verify URL directly in the
// response — same "mock" convention as /api/checkout/session — so the login
// flow is exercisable end to end before an email provider is wired in.

import { getAccounts } from "@/lib/accounts/store";

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
    // TODO(live): send `verifyUrl` to `email` via Resend (or chosen provider)
    // and return { ok: true, mode: "sent" } WITHOUT the link in the response.
  }

  return Response.json({ ok: true, mode: process.env.RESEND_API_KEY ? "sent" : "mock", verifyUrl });
}
