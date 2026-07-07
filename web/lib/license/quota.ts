// Server-enforced free-tier quota. The app meters locally for snappy UX, but
// THIS is the real guard: it protects the Anthropic bill (= product margin)
// from a client that lies about its remaining drafts. Pro/trial are unlimited.

import type { ConnectionsStore } from "../connections/memoryStore";

/** Must match the Swift `Entitlements.freeDraftsPerWeek`. */
export const FREE_DRAFTS_PER_WEEK = 15;

const WEEK_MS = 7 * 86_400_000;

/** Fixed 7-day buckets anchored to the epoch — deterministic, no per-device
    drift, trivially testable. */
export function weekStart(nowMs: number): number {
  return nowMs - (nowMs % WEEK_MS);
}

export interface QuotaResult {
  allowed: boolean;
  /** Drafts left this week (null = unlimited on pro/trial). */
  remaining: number | null;
}

/** Check the quota and consume one draft when allowed. Unlimited (Pro/trial —
    resolved from the account subscription by the caller) skips the counter
    entirely; the weekly usage counter itself stays in the (ephemeral) sync
    store. */
export function checkAndConsume(store: ConnectionsStore, deviceId: string, nowMs: number, unlimited: boolean): QuotaResult {
  if (unlimited) return { allowed: true, remaining: null };

  const ws = weekStart(nowMs);
  const cur = store.usage(deviceId);
  const usedThisWeek = cur.weekStart === ws ? cur.count : 0;
  if (usedThisWeek >= FREE_DRAFTS_PER_WEEK) return { allowed: false, remaining: 0 };

  const next = store.bumpUsage(deviceId, ws);
  return { allowed: true, remaining: Math.max(0, FREE_DRAFTS_PER_WEEK - next.count) };
}
