// GET /api/health — uptime probe + the app's incident banner source. Set
// OSMO_STATUS=degraded (or down) and OSMO_STATUS_MESSAGE="…" to broadcast an
// incident to every running client without shipping an update.

export const dynamic = "force-dynamic";

export async function GET(): Promise<Response> {
  const status = (process.env.OSMO_STATUS ?? "operational").toLowerCase();
  const message = process.env.OSMO_STATUS_MESSAGE ?? null;
  return Response.json({ ok: status === "operational", status, message });
}
