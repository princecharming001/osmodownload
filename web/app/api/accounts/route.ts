// GET /api/accounts — the caller's connections + status (reconciliation
// snapshot for the app). PATCH ?id= {action:"pause"|"resume"} toggles sync.
// DELETE ?id= disconnects.

import { AuthError, requireDevice, unauthorized } from "@/lib/connections/auth";
import { getStore } from "@/lib/connections/memoryStore";
import { ensureConnectionsLoaded } from "@/lib/connections/connectionsDurable";
import { publish } from "@/lib/connections/events";
import { stopDrip } from "@/lib/unipile/mock";
import { accountIsHealthy, getUnipile } from "@/lib/unipile/client";
import { platformForProvider } from "@/lib/unipile/normalize";
import { backfillConnection } from "@/lib/connections/backfill";
import { resyncConnection } from "@/lib/connections/resync";
import { verifyConnections } from "@/lib/connections/liveness";
import type { AccountsResponse, Connection } from "@/lib/connections/types";
import { readJsonObject } from "@/lib/http";

/** Devices we've already attempted adoption for this process (one shot each). */
const adopted = new Set<string>();

/** SINGLE-TENANT restart-heal, DISABLED by default. When a server restart drops
    the in-memory connections, the accounts still exist at Unipile — this would
    re-attach them to the first connection-less device that asks. But with real
    user accounts that's WRONG: it shows one Unipile tenant's WhatsApp/LinkedIn/
    Instagram as "Connected" on a BRAND-NEW account. A new account must start
    empty; users connect their OWN platforms via the connect flow. Only enable
    on a single-tenant dev/demo box by setting OSMO_ADOPT_ORPHANS=1. */
async function adoptOrphanedAccounts(deviceId: string): Promise<void> {
  if (process.env.OSMO_ADOPT_ORPHANS !== "1") return;   // off by default → new accounts are empty
  const store = getStore();
  if (adopted.has(deviceId) || store.connections(deviceId).length > 0) return;
  adopted.add(deviceId);
  const unipile = getUnipile();
  if (unipile.mode !== "live") return;
  try {
    const seenPlatforms = new Set<string>();   // e.g. two Instagram sessions → adopt one
    for (const account of await unipile.listAccounts()) {
      const platform = platformForProvider(account.provider ?? account.type);
      if (!platform || !accountIsHealthy(account)) continue;
      if (seenPlatforms.has(platform)) continue;
      seenPlatforms.add(platform);
      const connection: Connection = {
        id: account.id, deviceId, platform, status: "backfilling",
        displayName: account.name || platform, backfillProgress: 0,
        createdAt: new Date().toISOString(),
      };
      store.addConnection(connection);
      publish(deviceId, {
        type: "connection.status", platform, status: "backfilling", connectionId: account.id,
      });
      console.log(`[adopt] re-adopted ${platform}/${account.id} after restart; backfilling`);
      void backfillConnection({ deviceId, accountId: account.id, platform });
    }
  } catch (err) {
    console.error("[adopt] failed:", (err as Error).message);
  }
}

export async function GET(req: Request): Promise<Response> {
  try {
    const device = await requireDevice(req);
    await ensureConnectionsLoaded(device.id); // rehydrate durable connections after a redeploy
    await adoptOrphanedAccounts(device.id);
    // ?verify=1 → check stored statuses against upstream account health
    // (TTL-throttled server-side; no-op in mock mode).
    if (new URL(req.url).searchParams.get("verify") === "1") await verifyConnections(device.id);
    const connections = getStore().connections(device.id)
      .map(({ deviceId: _omit, ...rest }) => rest);
    const res: AccountsResponse = { connections };
    return Response.json(res);
  } catch (e) {
    if (e instanceof AuthError) return unauthorized();
    throw e;
  }
}

export async function PATCH(req: Request): Promise<Response> {
  try {
    const device = await requireDevice(req);
    const id = new URL(req.url).searchParams.get("id") ?? "";
    const body = await readJsonObject(req);
    const action = body.action as string | undefined;
    await ensureConnectionsLoaded(device.id); // rehydrate after redeploy before the lookup
    const store = getStore();
    const conn = store.connectionById(id);
    if (!conn || conn.deviceId !== device.id) {
      return Response.json({ error: "unknown connection" }, { status: 404 });
    }
    if (action === "pause") store.setConnectionStatus(id, "paused");
    else if (action === "resume") store.setConnectionStatus(id, "connected");
    else return Response.json({ error: "action must be pause|resume" }, { status: 400 });
    publish(device.id, {
      type: "connection.status", platform: conn.platform,
      status: action === "pause" ? "paused" : "connected", connectionId: id,
    });
    if (action === "resume") {
      // Webhooks that arrived WHILE paused were hard-dropped (unipile/route.ts)
      // rather than buffered — resuming must actively catch up on whatever
      // was missed instead of silently waiting for the next incidental
      // message. Fire-and-forget, same dispatch as "re-import history";
      // idempotent, so catching up on nothing costs nothing but a scan.
      void resyncConnection(device.id, id, conn.platform);
    }
    return Response.json({ ok: true });
  } catch (e) {
    if (e instanceof AuthError) return unauthorized();
    throw e;
  }
}

export async function DELETE(req: Request): Promise<Response> {
  try {
    const device = await requireDevice(req);
    const id = new URL(req.url).searchParams.get("id") ?? "";
    await ensureConnectionsLoaded(device.id); // rehydrate after redeploy before the lookup
    const store = getStore();
    const conn = store.connectionById(id);
    if (!conn || conn.deviceId !== device.id) {
      return Response.json({ error: "unknown connection" }, { status: 404 });
    }
    stopDrip(id);
    store.removeConnection(id);
    publish(device.id, {
      type: "connection.status", platform: conn.platform,
      status: "disconnected", connectionId: id,
    });
    return Response.json({ ok: true });
  } catch (e) {
    if (e instanceof AuthError) return unauthorized();
    throw e;
  }
}
