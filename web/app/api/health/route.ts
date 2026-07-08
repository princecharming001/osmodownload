// GET /api/health — uptime probe + readiness + operational metrics + the app's
// incident banner source. Set OSMO_STATUS=degraded (or down) and
// OSMO_STATUS_MESSAGE="…" to broadcast an incident to every client without an
// update. `ready.db` is a cheap durable-store reachability probe; `metrics` is
// the in-process counter snapshot (draft.ok, draft.upstream_error, …).

import { getMetrics } from "@/lib/obs";
import { getAccounts, accountsAreLive } from "@/lib/accounts/store";

export const dynamic = "force-dynamic";

export async function GET(): Promise<Response> {
  const status = (process.env.OSMO_STATUS ?? "operational").toLowerCase();
  const message = process.env.OSMO_STATUS_MESSAGE ?? null;

  let db: "ok" | "down" | "n/a" = "n/a";
  if (accountsAreLive()) {
    try { await getAccounts().deviceById("__health_probe__"); db = "ok"; }
    catch { db = "down"; }
  }

  return Response.json({
    ok: status === "operational" && db !== "down",
    status,
    message,
    ready: { db },
    metrics: getMetrics(),
  });
}
