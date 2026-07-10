// POST /api/feedback { message, meta? } — in-app feedback / bug reports.
// Scaffold: logs server-side (and forwards to a webhook if OSMO_FEEDBACK_WEBHOOK
// is set — Slack/Discord/email relay). Never stores message content anywhere
// persistent here.

import { AuthError, requireDevice, unauthorized } from "@/lib/connections/auth";
import { readJsonObject } from "@/lib/http";

export async function POST(req: Request): Promise<Response> {
  try {
    const device = await requireDevice(req);
    const body = await readJsonObject(req) as { message?: string; meta?: string };
    const message = (body.message ?? "").toString().slice(0, 5000).trim();
    if (!message) return Response.json({ error: "empty" }, { status: 400 });

    const line = `[feedback] device=${device.id} meta=${body.meta ?? "-"} :: ${message}`;
    console.log(line);

    const hook = process.env.OSMO_FEEDBACK_WEBHOOK;
    if (hook) {
      // Fire-and-forget relay; never block the user's submit on it.
      void fetch(hook, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ text: line }),
      }).catch(() => {});
    }
    return Response.json({ ok: true });
  } catch (e) {
    if (e instanceof AuthError) return unauthorized();
    throw e;
  }
}
