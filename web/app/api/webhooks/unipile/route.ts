// POST /api/webhooks/unipile — live-mode receiver for message_received /
// account.status webhooks. Always 200s fast (Unipile retries on failure and
// polling reconciles anyway). Shared-secret check when configured.

import { getStore } from "@/lib/connections/memoryStore";
import { publish } from "@/lib/connections/events";
import { normalizeMessageWebhook, platformForProvider } from "@/lib/unipile/normalize";

export async function POST(req: Request): Promise<Response> {
  const secret = process.env.OSMO_WEBHOOK_SECRET;
  if (secret && req.headers.get("x-osmo-webhook-secret") !== secret) {
    return Response.json({ error: "bad secret" }, { status: 401 });
  }

  const payload = await req.json().catch(() => null) as Record<string, unknown> | null;
  if (!payload) return Response.json({ ok: true });

  const store = getStore();
  const accountId = (payload.account_id ?? payload.accountId) as string | undefined;
  const connection = accountId ? store.connectionById(accountId) : null;
  if (!connection) return Response.json({ ok: true });   // not ours / not yet linked

  const event = String(payload.event ?? payload.type ?? "");

  if (event.includes("message")) {
    if (connection.status === "paused") return Response.json({ ok: true });
    const bundle = normalizeMessageWebhook(payload);
    if (bundle) {
      const seq = store.appendRows(connection.deviceId, bundle);
      if (seq > 0) publish(connection.deviceId, { type: "sync.dirty", seq });
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
  return Response.json({ ok: true });
}
