// Minimal Resend email send (raw fetch, no SDK dependency). Returns true on a
// 2xx from Resend, false otherwise (including when no key is configured).
//
// The RESEND_API_KEY and a verified sender domain are a HUMAN GATE (see
// HUMAN-GATES.md) — this is the code that will use them once they exist. Until
// then the magic-link route stays in dev mode (link shown locally, never in prod).

export async function sendMagicLink(to: string, verifyUrl: string): Promise<boolean> {
  const key = process.env.RESEND_API_KEY;
  if (!key) return false;
  const from = process.env.OSMO_EMAIL_FROM ?? "Osmo <login@leftonread.in>";
  try {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { authorization: `Bearer ${key}`, "content-type": "application/json" },
      body: JSON.stringify({
        from,
        to,
        subject: "Your Osmo sign-in link",
        text:
          `Sign in to Osmo:\n\n${verifyUrl}\n\n` +
          `This link expires in 15 minutes and can only be used once. ` +
          `If you didn't request it, you can ignore this email.`,
      }),
    });
    return res.ok;
  } catch {
    return false;
  }
}
