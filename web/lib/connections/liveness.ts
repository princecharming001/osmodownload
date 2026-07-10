// Connection liveness — makes /api/accounts?verify=1 reflect the TRUTH at
// Unipile instead of whatever status happened to be stored. One listAccounts()
// per device per TTL, each Unipile-backed connection mapped through
// accountIsHealthy: unhealthy/absent upstream → degraded, recovered → connected
// (both published on the existing connection.status SSE). A failed Unipile
// FETCH never downgrades anything — only an authoritative unhealthy answer
// does, so a flaky verify can't flap the UI.

import { getStore } from "./memoryStore";
import { publish } from "./events";
import type { Platform } from "./types";
import { accountIsHealthy, getUnipile } from "../unipile/client";

const TTL_MS = Number(process.env.OSMO_VERIFY_TTL_MS ?? 5 * 60_000);
const FAILURE_TTL_MS = 60_000;   // short penalty so a down Unipile isn't hammered

// globalThis cache: deviceId → epoch ms until which verification is considered
// fresh (hot-reload safe, same pattern as events.ts).
const g = globalThis as unknown as {
  __osmoVerifiedUntil?: Map<string, number>;
};

function verifiedUntil(): Map<string, number> {
  g.__osmoVerifiedUntil ??= new Map();
  return g.__osmoVerifiedUntil;
}

/** Platforms whose sessions live at Unipile (gmail/slack/x are OAuth-backed;
    iMessage never touches the backend). Only these can be verified here. */
const UNIPILE_PLATFORMS = new Set<Platform>(["linkedin", "whatsapp", "instagram"]);

/** Verify a device's Unipile-backed connections against upstream account
    health, flipping connected↔degraded in the store + SSE. No-op in mock/
    keyless mode and within the TTL. Never touches paused/disconnected/linking
    connections (user intent) and never downgrades on a fetch failure. */
export async function verifyConnections(deviceId: string): Promise<void> {
  const unipile = getUnipile();
  if (unipile.mode !== "live") return;   // keyless/e2e.sh untouched
  const now = Date.now();
  if ((verifiedUntil().get(deviceId) ?? 0) > now) return;

  let accounts;
  try {
    accounts = await unipile.listAccounts();
  } catch (err) {
    // A flaky verify must not flap the UI — leave statuses alone, back off briefly.
    verifiedUntil().set(deviceId, now + FAILURE_TTL_MS);
    console.error("[liveness] listAccounts failed:", (err as Error).message);
    return;
  }
  verifiedUntil().set(deviceId, now + TTL_MS);
  const byId = new Map(accounts.map((a) => [a.id, a]));

  const store = getStore();
  const stamp = new Date().toISOString();
  for (const conn of store.connections(deviceId)) {
    if (!UNIPILE_PLATFORMS.has(conn.platform)) continue;
    if (!["connected", "backfilling", "degraded"].includes(conn.status)) continue;
    const account = byId.get(conn.id);
    const healthy = account ? accountIsHealthy(account) : false;
    store.touchConnection(conn.id, { lastVerifiedAt: stamp });
    if (!healthy && conn.status !== "degraded") {
      store.setConnectionStatus(conn.id, "degraded");
      publish(deviceId, { type: "connection.status", platform: conn.platform, status: "degraded", connectionId: conn.id });
    } else if (healthy && conn.status === "degraded") {
      store.setConnectionStatus(conn.id, "connected");
      publish(deviceId, { type: "connection.status", platform: conn.platform, status: "connected", connectionId: conn.id });
    }
  }
}

/** Test-only: forget every device's verify timestamp. */
export function resetLivenessForTests(): void {
  g.__osmoVerifiedUntil = new Map();
}
