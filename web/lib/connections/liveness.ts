// Connection liveness — makes /api/accounts?verify=1 reflect the TRUTH
// upstream instead of whatever status happened to be stored. Two passes, both
// TTL-throttled per device and both published on the existing
// connection.status SSE:
//   • Unipile-backed platforms: one listAccounts() per device per TTL, each
//     connection mapped through accountIsHealthy — unhealthy/absent upstream →
//     degraded, recovered → connected. An EMPTY account list while the device
//     holds live Unipile connections is treated as a partial/failed upstream
//     read (absent → unhealthy is only trustworthy from a plausibly-complete
//     list) — no flips, short backoff.
//   • OAuth-backed gmail/slack: refresh via the existing token helper, then
//     the cheapest authenticated probe (Gmail /profile, Slack auth.test).
//     Only an AUTHORITATIVE auth failure (401 / ok:false) downgrades.
// A failed upstream FETCH never downgrades anything — a flaky verify can't
// flap the UI.

import { getStore } from "./memoryStore";
import { publish } from "./events";
import type { Connection, Platform } from "./types";
import { accountIsHealthy, getUnipile } from "../unipile/client";
import { isLiveOAuth } from "../oauth/providers";
import { freshOAuthToken } from "../oauth/tokens";

const TTL_MS = Number(process.env.OSMO_VERIFY_TTL_MS ?? 5 * 60_000);
const FAILURE_TTL_MS = 60_000;   // short penalty so a down upstream isn't hammered

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
    iMessage never touches the backend). */
const UNIPILE_PLATFORMS = new Set<Platform>(["linkedin", "whatsapp", "instagram"]);

type OAuthVerdict = "healthy" | "unauthorized" | "unknown";

/** Probe one OAuth platform with the cheapest authenticated call. Only an
    authoritative auth failure returns "unauthorized"; a timeout/5xx (or a
    missing/unreadable token bundle) is "unknown" — never a downgrade. */
async function verifyOAuthAccount(deviceId: string, platform: "gmail" | "slack"): Promise<OAuthVerdict> {
  let bundle: Record<string, unknown>;
  try {
    bundle = await freshOAuthToken(deviceId, platform);
  } catch {
    return "unknown";   // token-store read failure ≠ an auth verdict
  }
  const token = platform === "slack"
    ? (bundle as { authed_user?: { access_token?: string } }).authed_user?.access_token
    : (bundle as { access_token?: string }).access_token;
  if (!token) return "unknown";   // absent bundle is not authoritative either
  try {
    if (platform === "gmail") {
      // freshOAuthToken already refreshed (or failed to — invalid_grant leaves
      // the stale token in place, which this probe then 401s on).
      const res = await fetch("https://gmail.googleapis.com/gmail/v1/users/me/profile", {
        headers: { Authorization: `Bearer ${token}` },
      });
      if (res.status === 401) return "unauthorized";
      return res.ok ? "healthy" : "unknown";
    }
    // slack — auth.test 200s even for dead tokens; ok:false is the verdict.
    const res = await fetch("https://slack.com/api/auth.test", {
      method: "POST",
      headers: { Authorization: `Bearer ${token}` },
    });
    if (!res.ok) return "unknown";
    const data = await res.json() as { ok?: boolean };
    return data.ok ? "healthy" : "unauthorized";
  } catch {
    return "unknown";   // network failure ≠ downgrade
  }
}

/** Verify a device's connections against upstream health, flipping
    connected↔degraded in the store + SSE. No-op in keyless/mock mode and
    within the TTL. Never touches paused/disconnected/linking connections
    (user intent) and never downgrades on a fetch failure. */
export async function verifyConnections(deviceId: string): Promise<void> {
  const now = Date.now();
  if ((verifiedUntil().get(deviceId) ?? 0) > now) return;

  const store = getStore();
  const stamp = new Date().toISOString();
  let ttl = TTL_MS;

  const apply = (conn: Connection, healthy: boolean) => {
    store.touchConnection(conn.id, { lastVerifiedAt: stamp });
    if (!healthy && conn.status !== "degraded") {
      store.setConnectionStatus(conn.id, "degraded");
      publish(deviceId, { type: "connection.status", platform: conn.platform, status: "degraded", connectionId: conn.id });
    } else if (healthy && conn.status === "degraded") {
      store.setConnectionStatus(conn.id, "connected");
      publish(deviceId, { type: "connection.status", platform: conn.platform, status: "connected", connectionId: conn.id });
    }
  };

  const active = store.connections(deviceId)
    .filter((c) => ["connected", "backfilling", "degraded"].includes(c.status));

  // Pass 1 — Unipile-backed platforms (one listAccounts per device per TTL).
  const unipile = getUnipile();
  const unipileConns = active.filter((c) => UNIPILE_PLATFORMS.has(c.platform));
  if (unipile.mode === "live" && unipileConns.length > 0) {
    try {
      const accounts = await unipile.listAccounts();
      if (accounts.length === 0) {
        // The device holds ≥1 live Unipile connection, yet upstream says it
        // has NO accounts at all — that smells like a partial/failed read,
        // and "absent → unhealthy" is only trustworthy from a plausibly-
        // complete list. Skip flips for this run, back off briefly.
        ttl = FAILURE_TTL_MS;
        console.error("[liveness] empty account list with live connections — skipping status flips");
      } else {
        const byId = new Map(accounts.map((a) => [a.id, a]));
        for (const conn of unipileConns) {
          const account = byId.get(conn.id);
          apply(conn, account ? accountIsHealthy(account) : false);
        }
      }
    } catch (err) {
      // A flaky verify must not flap the UI — leave statuses alone, back off briefly.
      ttl = FAILURE_TTL_MS;
      console.error("[liveness] listAccounts failed:", (err as Error).message);
    }
  }

  // Pass 2 — OAuth-backed gmail/slack (the tokens that actually expire).
  // x is skipped: its DM API is rate-limited enough that a verify probe would
  // eat the real sync budget. Keyless/mock connections are never touched.
  for (const conn of active) {
    if (conn.platform !== "gmail" && conn.platform !== "slack") continue;
    if (!isLiveOAuth(conn.platform)) continue;
    const verdict = await verifyOAuthAccount(deviceId, conn.platform);
    if (verdict === "unknown") continue;   // network failure ≠ downgrade
    apply(conn, verdict === "healthy");
  }

  verifiedUntil().set(deviceId, now + ttl);
}

/** Test-only: forget every device's verify timestamp. */
export function resetLivenessForTests(): void {
  g.__osmoVerifiedUntil = new Map();
}
