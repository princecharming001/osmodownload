// OAuth token access with durability: read from the in-memory sync store first
// (fast), fall back to the durable osmo_oauth_tokens table (rehydrating memory)
// so connections survive a redeploy; writes go to BOTH. Same memory-first pattern
// as device tokens.

import { getStore } from "@/lib/connections/memoryStore";
import { getAccounts } from "@/lib/accounts/store";
import type { Platform } from "@/lib/connections/types";

export async function getOAuthTokens(
  deviceId: string, platform: Platform,
): Promise<Record<string, unknown> | null> {
  const mem = getStore().oauthTokens(deviceId, platform) as Record<string, unknown> | null;
  if (mem) return mem;
  const durable = await getAccounts().oauthTokens(deviceId, platform);
  if (durable) getStore().setOAuthTokens(deviceId, platform, durable); // rehydrate this process
  return durable;
}

export async function putOAuthTokens(
  deviceId: string, platform: Platform, tokens: Record<string, unknown>,
): Promise<void> {
  getStore().setOAuthTokens(deviceId, platform, tokens);          // fast path for this process
  await getAccounts().setOAuthTokens(deviceId, platform, tokens); // durable
}
