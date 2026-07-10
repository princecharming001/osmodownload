// POST /api/webhooks/unipile — live-mode receiver for message_received /
// account.status webhooks. Always 200s fast (Unipile retry-storms on 5xx and
// polling reconciles anyway), so the whole handler is wrapped: a surprise
// throw degrades to an acknowledged no-op, never a 500. Shared-secret check
// when configured.

import { getStore } from "@/lib/connections/memoryStore";
import { ensureConnectionById } from "@/lib/connections/connectionsDurable";
import { publish } from "@/lib/connections/events";
import { normalizeMessageWebhook, platformForProvider } from "@/lib/unipile/normalize";

export async function POST(req: Request): Promise<Response> {
  const secret = process.env.OSMO_WEBHOOK_SECRET;
  if (secret && req.headers.get("x-osmo-webhook-secret") !== secret) {
    return Response.json({ error: "bad secret" }, { status: 401 });
  }

  const parsed = await req.json().catch(() => null) as unknown;
  // Tolerate any JSON scalar/array Unipile (or a fuzzer) might send — only a
  // plain object can carry an event we understand.
  const payload = (parsed && typeof parsed === "object" && !Array.isArray(parsed))
    ? parsed as Record<string, unknown>
    : null;
  if (!payload) return Response.json({ ok: true });

  try {
    const store = getStore();
    const rawAccountId = payload.account_id ?? payload.accountId;
    const accountId = typeof rawAccountId === "string" ? rawAccountId : null;
    // In-memory first; after a redeploy the map is empty but the durable row
    // survives — without this fallback every webhook between the restart and
    // the app's next /api/accounts call was silently dropped.
    const connection = accountId ? await ensureConnectionById(accountId) : null;
    if (!connection) return Response.json({ ok: true });   // not ours / not yet linked

    const event = String(payload.event ?? payload.type ?? "");

    if (event.includes("message")) {
      if (connection.status === "paused") return Response.json({ ok: true });
      const bundle = normalizeMessageWebhook(payload);
      if (bundle) {
        const seq = store.appendRows(connection.deviceId, bundle);
        if (seq > 0) {
          store.touchConnection(connection.id, { lastSyncAt: new Date().toISOString() });
          publish(connection.deviceId, { type: "sync.dirty", seq });
        }
      }
    } else if (event.includes("account")) {
      const status = String(payload.status ?? "").toUpperCase();
      const platform = platformForProvider(payload.account_type as string) ?? connection.platform;
      if (status === "CREDENTIALS" || status === "ERROR" || status === "STOPPED") {
        store.setConnectionStatus(connection.id, "degraded");
        publish(connection.deviceId, {
          type: "connection.status", platform, status: "degraded", connectionId: connection.id,
        });
      } else if (status === "OK" || status === "CONNECTED") {
        store.setConnectionStatus(connection.id, "connected");
        publish(connection.deviceId, {
          type: "connection.status", platform, status: "connected", connectionId: connection.id,
        });
      }
    }
  } catch (err) {
    // Never bounce a 5xx back at Unipile — log and acknowledge; the 60s
    // reconciliation poll re-covers anything a dropped event would have carried.
    console.error("[unipile webhook] ingest failed:", (err as Error).message);
  }
  return Response.json({ ok: true });
}
