// Rehydrate a device's connections from the durable store (osmo_connections)
// after a redeploy, when the in-memory set is empty. Connection WRITES are made
// durable inside memoryStore (addConnection/setConnectionStatus/removeConnection
// fire-and-forget to osmo_connections); this is the READ-side complement so
// /api/accounts reflects reality instead of showing everything disconnected.

import { getAccounts } from "@/lib/accounts/store";
import { getStore } from "./memoryStore";
import type { Connection, ConnectionStatus, Platform } from "./types";

const KNOWN_PLATFORMS = new Set<Platform>([
  "imessage", "gmail", "slack", "whatsapp", "linkedin", "x", "instagram",
]);
const KNOWN_STATUSES = new Set<ConnectionStatus>([
  "linking", "backfilling", "connected", "degraded", "paused", "disconnected",
]);

/** Decode-tolerant gate on a durable row. A partially-written or hand-edited
    Supabase row (unknown platform, null status) must degrade to "skipped", not
    crash /api/accounts or feed the Swift client an enum it can't decode. */
export function isValidDurableConnection(c: Partial<Connection> | null | undefined): c is Connection {
  return !!c
    && typeof c.id === "string" && c.id.length > 0
    && typeof c.deviceId === "string" && c.deviceId.length > 0
    && KNOWN_PLATFORMS.has(c.platform as Platform)
    && KNOWN_STATUSES.has(c.status as ConnectionStatus);
}

/** Coerce the optional fields a junk row may carry so downstream code (and the
    wire contract) always sees the declared shapes. Call only on valid rows. */
function sanitizeDurableConnection(c: Connection): Connection {
  return {
    ...c,
    displayName: typeof c.displayName === "string" ? c.displayName : "",
    backfillProgress: typeof c.backfillProgress === "number" && Number.isFinite(c.backfillProgress)
      ? c.backfillProgress : 0,
    createdAt: typeof c.createdAt === "string" ? c.createdAt : new Date().toISOString(),
    lastSyncAt: typeof c.lastSyncAt === "string" ? c.lastSyncAt : null,
    lastVerifiedAt: typeof c.lastVerifiedAt === "string" ? c.lastVerifiedAt : null,
  };
}

export async function ensureConnectionsLoaded(deviceId: string): Promise<void> {
  const store = getStore();
  if (store.connections(deviceId).length > 0) return; // already warm in this process
  const durable = await getAccounts().connectionsForDevice(deviceId);
  for (const c of durable) {
    if (!isValidDurableConnection(c)) continue;   // tolerate partial/corrupt rows
    store.hydrateConnection(demoteStaleBackfill(sanitizeDurableConnection(c)));
  }
}

/** Webhook-path rehydration: look one connection up by id (webhooks carry the
    account id, not a device), hydrate it into memory when found. Returns the
    in-memory record either way. */
export async function ensureConnectionById(id: string): Promise<Connection | null> {
  const store = getStore();
  const warm = store.connectionById(id);
  if (warm) return warm;
  const durable = await getAccounts().connectionById(id).catch(() => null);
  if (!isValidDurableConnection(durable)) return null;
  store.hydrateConnection(demoteStaleBackfill(sanitizeDurableConnection(durable)));
  return store.connectionById(id);
}

/** An import does not survive the process — a REHYDRATED "backfilling" row is
    a lie (the X connect stuck at "Importing history… 0%" forever). Demote to
    degraded so the UI offers Reconnect instead of an infinite spinner. */
function demoteStaleBackfill(c: Connection): Connection {
  if (c.status !== "backfilling") return c;
  return { ...c, status: "degraded" };
}
