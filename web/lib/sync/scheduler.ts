// The incremental sync scheduler — the fix for "Gmail/Slack/X never update
// automatically." Before this, a new message on those three platforms only
// ever entered the oplog via the one-time OAuth-connect backfill or a user
// manually tapping "re-import history" — verified via code audit: no watch/
// Pub-Sub, no Events API subscription, no cron, anywhere. LinkedIn/WhatsApp/
// Instagram (Unipile) already get real webhooks; this closes the gap for the
// three platforms that don't have one.
//
// Deliberately reuses resyncConnection() — the EXACT same dispatch the
// user-facing "re-import history" button already calls — rather than new
// per-platform delta-fetch logic. That keeps this addition to "call proven
// code on a timer," not "three new untested fetch paths." The cost is a
// bounded full-window rescan per tick instead of a true incremental delta;
// ingest already dedupes on (platform, messageID), so a rescan is always
// correct, just less quota-efficient than a real delta would be. A true
// per-provider delta (Gmail history.list, Slack conversations.history
// cursor, X since_id) is the natural v2 upgrade.
//
// Freshness: defaults give a worst-case of staleAfterMs + tickIntervalMs
// (~15 min), not the ~90s originally scoped. Deliberate, not an oversight:
// a full-window rescan every 90s per connection would burn through Gmail/
// Slack/X rate limits (especially X's tight non-enterprise DM caps) long
// before the v2 delta upgrade lands to make a fast cadence cheap. Tightening
// this is a quota-vs-freshness tradeoff for a real delta implementation,
// not a config change.

import { accountsAreLive, getAccounts } from "../accounts/store";
import { ensureConnectionsLoaded } from "../connections/connectionsDurable";
import { resyncConnection, type ResyncResult } from "../connections/resync";
import { envInt } from "../connections/scope";
import type { Connection, Platform } from "../connections/types";

const SYNCED_PLATFORMS = ["gmail", "slack", "x"] as const;

const g = globalThis as unknown as { __osmoSyncScheduler?: ReturnType<typeof setInterval> };

/** How often the scheduler wakes up to check for stale connections. */
function tickIntervalMs(): number { return envInt("OSMO_SYNC_TICK_MS", 5 * 60_000); }
/** How long a connection can go without a sync before it's due again — the
    real cadence users see. Clamped to never fall below the tick interval —
    an operator setting OSMO_SYNC_STALE_MS below OSMO_SYNC_TICK_MS would
    otherwise mean every connection is stale again by the time the next tick
    fires, i.e. "resync everything every tick." The clamp makes that an
    enforced invariant rather than just a comment. */
function staleAfterMs(): number {
  return Math.max(envInt("OSMO_SYNC_STALE_MS", 10 * 60_000), tickIntervalMs());
}

/** Real delay, injectable so tests never actually wait. Spreads a burst of
    simultaneously-due connections (e.g. every connection is "due" on the
    very first tick after a deploy or an outage) out over time instead of
    firing every backfill at once — bounds the worst-case upstream API
    burst without needing a full concurrency-limiter. */
function realSleep(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms));
}
const STAGGER_MS = 1_500;

export interface TickDeps {
  listConnections: (platforms: string[]) => Promise<Connection[]>;
  ensureLoaded: (deviceId: string) => Promise<void>;
  resync: (deviceId: string, connectionId: string, platform: Platform) => Promise<ResyncResult>;
  now: () => number;
  /** Stagger delay between due-connection dispatches. Optional — omitted
      (as every existing test's deps object is) means no stagger, so the
      suite stays instant; only `liveDeps` wires a real timer. */
  sleep?: (ms: number) => Promise<void>;
}

const liveDeps: TickDeps = {
  listConnections: (platforms) => getAccounts().connectedConnectionsByPlatforms(platforms),
  ensureLoaded: ensureConnectionsLoaded,
  resync: resyncConnection,
  now: () => Date.now(),
  sleep: realSleep,
};

/** The pure fan-out: which connections are due, resync each, one failure
    never stops the rest. Dependency-injected so it's testable without a
    live durable store or real provider calls — `tick()` below is the only
    caller that hits real infrastructure. */
export async function runTick(deps: TickDeps = liveDeps): Promise<{ attempted: string[]; failed: string[] }> {
  const attempted: string[] = [];
  const failed: string[] = [];
  let connections: Connection[];
  try {
    connections = await deps.listConnections([...SYNCED_PLATFORMS]);
  } catch (err) {
    console.error("[sync scheduler] failed to list connections:", (err as Error).message);
    return { attempted, failed };
  }
  const cutoff = deps.now() - staleAfterMs();
  const due = connections.filter(c => !c.lastSyncAt || Date.parse(c.lastSyncAt) < cutoff);
  for (const [i, conn] of due.entries()) {
    if (i > 0 && deps.sleep) await deps.sleep(STAGGER_MS);
    attempted.push(conn.id);
    try {
      await deps.ensureLoaded(conn.deviceId);
      const result = await deps.resync(conn.deviceId, conn.id, conn.platform);
      if (!result.ok) {
        failed.push(conn.id);
        console.error(`[sync scheduler] ${conn.platform} resync for ${conn.id}: ${result.error}`);
      }
    } catch (err) {
      // One connection's failure (revoked token, transient network) must
      // never stop the rest of the fan-out.
      failed.push(conn.id);
      console.error(`[sync scheduler] ${conn.platform} resync for ${conn.id} threw:`, (err as Error).message);
    }
  }
  return { attempted, failed };
}

async function tick(): Promise<void> {
  if (!accountsAreLive()) return;   // never in mock/dev/test — durable-only
  await runTick(liveDeps);
}

/** Start the scheduler once per server process. Idempotent — safe to call
    from instrumentation.ts even across Next.js dev hot-reloads. */
export function startIncrementalSyncScheduler(): void {
  if (g.__osmoSyncScheduler) return;
  if (!accountsAreLive()) return;   // no durable store to enumerate — nothing to do
  g.__osmoSyncScheduler = setInterval(() => { void tick(); }, tickIntervalMs());
}

export function resetSchedulerForTests(): void {
  if (g.__osmoSyncScheduler) clearInterval(g.__osmoSyncScheduler);
  g.__osmoSyncScheduler = undefined;
}
