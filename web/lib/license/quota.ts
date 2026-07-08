// Server-enforced free-tier quota. The app meters locally for snappy UX, but
// THIS is the real guard: it protects the Anthropic bill (= product margin)
// from a client that lies about its remaining drafts. Pro/trial are unlimited.

import type { ConnectionsStore } from "../connections/memoryStore";
import type { AccountsStore } from "../accounts/store";

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

/** Durable variant — the weekly counter lives in the accounts store (osmo_usage
    on Supabase when live), so it survives restart/redeploy. This is the path
    /api/suggest uses. */
export async function checkAndConsumeDurable(
  accounts: AccountsStore, deviceId: string, nowMs: number, unlimited: boolean,
): Promise<QuotaResult> {
  if (unlimited) return { allowed: true, remaining: null };

  const ws = weekStart(nowMs);
  const used = await accounts.usageCount(deviceId, ws);
  if (used >= FREE_DRAFTS_PER_WEEK) return { allowed: false, remaining: 0 };

  const next = await accounts.bumpUsage(deviceId, ws);
  return { allowed: true, remaining: Math.max(0, FREE_DRAFTS_PER_WEEK - next) };
}

/** Peek the quota WITHOUT consuming — the interactive path checks this BEFORE
    the model call so a draft that never gets produced (upstream failure) can't
    burn a credit. Pair with consumeQuotaDurable() after a successful generation. */
export async function peekQuotaDurable(
  accounts: AccountsStore, deviceId: string, nowMs: number, unlimited: boolean,
): Promise<QuotaResult> {
  if (unlimited) return { allowed: true, remaining: null };
  const used = await accounts.usageCount(deviceId, weekStart(nowMs));
  if (used >= FREE_DRAFTS_PER_WEEK) return { allowed: false, remaining: 0 };
  return { allowed: true, remaining: FREE_DRAFTS_PER_WEEK - used };
}

/** Consume one draft AFTER a successful generation (consume-on-success). */
export async function consumeQuotaDurable(accounts: AccountsStore, deviceId: string, nowMs: number): Promise<number> {
  const next = await accounts.bumpUsage(deviceId, weekStart(nowMs));
  return Math.max(0, FREE_DRAFTS_PER_WEEK - next);
}
