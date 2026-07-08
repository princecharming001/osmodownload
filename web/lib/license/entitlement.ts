// Pure entitlement resolution: a server LicenseRecord → a signed entitlement
// the app can verify offline. Kept separate from the routes so the tier logic
// is unit-tested and can't drift.

import type { LicenseRecord } from "../connections/memoryStore";
import { signEntitlement, type EntitlementPayload, type SignedEntitlement } from "./sign";
import { isProduction } from "../config/runtime";

export const TRIAL_DAYS = 14;
/** How long a signed entitlement stays valid offline before the app must
    re-validate. Long enough that a laptop offline for a trip keeps Pro; short
    enough that a cancelled subscription lapses within a week. */
export const OFFLINE_GRACE_DAYS = 7;

const DAY_MS = 86_400_000;

export function resolveTier(rec: LicenseRecord, nowMs: number): {
  tier: EntitlementPayload["tier"]; trialEndsAtMs?: number;
} {
  if (rec.subscriptionActive) return { tier: "pro" };
  if (rec.trialStartedAt != null) {
    const end = rec.trialStartedAt + TRIAL_DAYS * DAY_MS;
    if (nowMs < end) return { tier: "trial", trialEndsAtMs: end };
  }
  return { tier: "free" };
}

/** Build + sign the entitlement for a device given its current license state. */
export function buildSignedEntitlement(deviceId: string, rec: LicenseRecord, nowMs: number): SignedEntitlement {
  const { tier, trialEndsAtMs } = resolveTier(rec, nowMs);
  const issuedAt = Math.floor(nowMs / 1000);
  const payload: EntitlementPayload = {
    v: 1, deviceId, tier,
    issuedAt,
    expiresAt: issuedAt + OFFLINE_GRACE_DAYS * 86_400,
    ...(trialEndsAtMs ? { trialEndsAt: Math.floor(trialEndsAtMs / 1000) } : {}),
    ...(rec.trialStartedAt ? { trialStartedAt: Math.floor(rec.trialStartedAt / 1000) } : {}),
  };
  return signEntitlement(payload);
}

/** Validate a license key. Mock accepts any `OSMO-`-prefixed key as an active
    Pro license so the whole flow runs before the real licensing backend/Stripe
    lookup exists. Live validation (Stripe subscription / license server) wires
    in here — the routes never change. */
export function validateLicenseKey(key: string): { valid: boolean; plan: string | null } {
  const trimmed = key.trim().toUpperCase();
  // Mock acceptance is DEV-ONLY — a bare `OSMO-` prefix must never grant Pro in
  // production (that was the paywall-bypass finding). Real validation (Stripe
  // subscription / license server) wires in here; the routes never change.
  if (!isProduction() && trimmed.startsWith("OSMO-")) return { valid: true, plan: "com.osmo.pro.monthly" };
  return { valid: false, plan: null };
}
