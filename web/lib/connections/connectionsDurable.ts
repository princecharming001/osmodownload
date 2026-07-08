// Rehydrate a device's connections from the durable store (osmo_connections)
// after a redeploy, when the in-memory set is empty. Connection WRITES are made
// durable inside memoryStore (addConnection/setConnectionStatus/removeConnection
// fire-and-forget to osmo_connections); this is the READ-side complement so
// /api/accounts reflects reality instead of showing everything disconnected.

import { getAccounts } from "@/lib/accounts/store";
import { getStore } from "./memoryStore";

export async function ensureConnectionsLoaded(deviceId: string): Promise<void> {
  const store = getStore();
  if (store.connections(deviceId).length > 0) return; // already warm in this process
  const durable = await getAccounts().connectionsForDevice(deviceId);
  for (const c of durable) store.hydrateConnection(c);
}
