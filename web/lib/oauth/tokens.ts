// Valid-OAuth-token accessor: returns a fresh access-token bundle for a
// (device, platform), refreshing it when it's near expiry and re-persisting the
// result. Closes the "tokens never refreshed → Gmail dies ~1h, X ~2h" finding.
// Gmail + X refresh; Slack user tokens don't expire by default.

import { markConnectionDegraded } from "@/lib/connections/degrade";
import { getOAuthTokens, putOAuthTokens } from "./oauthStore";
import { refreshXToken, refreshGoogleToken } from "./providers";
import type { Platform } from "@/lib/connections/types";

type Bundle = Record<string, unknown> & {
  access_token?: string; refresh_token?: string; expires_in?: number; obtained_at?: number;
};

export async function freshOAuthToken(
  deviceId: string,
  platform: Platform,
  now: number = Date.now(),
): Promise<Bundle> {
  const bundle = ((await getOAuthTokens(deviceId, platform)) ?? {}) as Bundle;
  const obtainedAt = typeof bundle.obtained_at === "number" ? bundle.obtained_at : 0;
  const ttlMs = typeof bundle.expires_in === "number" ? bundle.expires_in * 1000 : Infinity;
  const expiresAt = obtainedAt + ttlMs;
  const nearExpiry = Number.isFinite(expiresAt) && now > expiresAt - 60_000;
  if (!nearExpiry || !bundle.refresh_token) return bundle;

  try {
    let refreshed: Bundle | null = null;
    if (platform === "x") refreshed = (await refreshXToken(bundle.refresh_token)) as Bundle;
    else if (platform === "gmail") refreshed = (await refreshGoogleToken(bundle.refresh_token)) as Bundle;
    else return bundle; // slack: no refresh
    const merged: Bundle = {
      ...bundle, ...refreshed,
      obtained_at: now,
      refresh_token: refreshed.refresh_token ?? bundle.refresh_token, // Google omits it on refresh
    };
    await putOAuthTokens(deviceId, platform, merged);
    return merged;
  } catch {
    // Refresh failed (revoked / expired refresh token) — flag the connection so
    // the user is prompted to reconnect rather than silently failing sends.
    markConnectionDegraded(deviceId, platform);
    return bundle;
  }
}
