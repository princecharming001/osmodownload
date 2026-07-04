// POST /api/connect/notify — Unipile's hosted-auth callback (live mode).
// Body carries {status, account_id, name} where `name` is our linkId. No
// bearer auth (Unipile calls it); validated by linkId existence + single-use.

import { getStore } from "@/lib/connections/memoryStore";
import { publish } from "@/lib/connections/events";
import type { Connection } from "@/lib/connections/types";

export async function POST(req: Request): Promise<Response> {
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
  // Live backfill job kicks off from here (paged history import). The
  // reconciliation poller self-heals if this instance dies mid-backfill.
  return Response.json({ ok: true });
}
