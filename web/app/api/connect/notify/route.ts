// POST /api/connect/notify — Unipile's hosted-auth callback (live mode).
// Body carries {status, account_id, name} where `name` is our linkId. No
// bearer auth (Unipile calls it); validated by linkId existence + single-use.

import { getStore } from "@/lib/connections/memoryStore";
import { publish } from "@/lib/connections/events";
import { backfillConnection } from "@/lib/connections/backfill";
import type { Connection } from "@/lib/connections/types";

export async function POST(req: Request): Promise<Response> {
  // Shared-secret gate: when configured, an unauthenticated caller can't bind an
  // arbitrary account_id to a victim's pending link. Unipile calls this URL and
  // can't send our header, so the secret rides in the query string we set on
  // notify_url; we also accept the header for symmetry. Skipped in mock mode.
  const secret = process.env.OSMO_WEBHOOK_SECRET;
  if (secret) {
    const provided = new URL(req.url).searchParams.get("secret")
      ?? req.headers.get("x-osmo-webhook-secret");
    if (provided !== secret) return Response.json({ error: "bad secret" }, { status: 401 });
  }

  const body = await req.json().catch(() => ({}));
  const linkId = (body.name ?? body.linkId) as string | undefined;
  const accountId = body.account_id as string | undefined;
  if (!linkId || !accountId) return Response.json({ ok: true });   // never error at Unipile

  const store = getStore();
  const link = store.resolvePendingLink(linkId);
  if (!link) return Response.json({ ok: true });

  const connection: Connection = {
    id: accountId,
    deviceId: link.deviceId,
    platform: link.platform,
    status: "backfilling",
    displayName: (body.account_name as string | undefined) ?? link.platform,
    backfillProgress: 0,
    createdAt: new Date().toISOString(),
  };
  store.addConnection(connection);
  publish(link.deviceId, {
    type: "connection.status", platform: link.platform,
    status: "backfilling", connectionId: accountId,
  });
  // Kick off the paged history import (fire-and-forget; the app's cursor-pull
  // drains it as rows land). Don't await — Unipile wants a fast 200.
  void backfillConnection({ deviceId: link.deviceId, accountId, platform: link.platform });
  return Response.json({ ok: true });
}
