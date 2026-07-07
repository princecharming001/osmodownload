import { describe, it, expect, beforeEach } from "vitest";
import crypto from "node:crypto";
import { signEntitlement, DEV_PUBLIC_X, type EntitlementPayload } from "@/lib/license/sign";
import { resolveTier, buildSignedEntitlement, validateLicenseKey, TRIAL_DAYS } from "@/lib/license/entitlement";
import { checkAndConsume, weekStart, FREE_DRAFTS_PER_WEEK } from "@/lib/license/quota";
import { resetStoreForTests, getStore, type LicenseRecord } from "@/lib/connections/memoryStore";

function verify(entitlement: string, signature: string): boolean {
  const pub = crypto.createPublicKey({ key: { kty: "OKP", crv: "Ed25519", x: DEV_PUBLIC_X }, format: "jwk" });
  return crypto.verify(null, Buffer.from(entitlement, "base64url"), pub, Buffer.from(signature, "base64url"));
}

function license(patch: Partial<LicenseRecord> = {}): LicenseRecord {
  return { deviceId: "dev-1", licenseKey: null, subscriptionActive: false, plan: null, trialStartedAt: null, ...patch };
}

const NOW = 1_800_000_000_000;   // fixed ms

describe("Ed25519 entitlement signing", () => {
  it("produces a signature the bundled public key verifies", () => {
    const payload: EntitlementPayload = { v: 1, deviceId: "dev-1", tier: "pro", issuedAt: 100, expiresAt: 200 };
    const signed = signEntitlement(payload);
    expect(verify(signed.entitlement, signed.signature)).toBe(true);
    // The entitlement decodes back to the exact payload.
    expect(JSON.parse(Buffer.from(signed.entitlement, "base64url").toString())).toEqual(payload);
  });

  it("a tampered payload fails verification (the anti-forgery property)", () => {
    const signed = signEntitlement({ v: 1, deviceId: "dev-1", tier: "free", issuedAt: 100, expiresAt: 200 });
    const forged = Buffer.from(JSON.stringify({ v: 1, deviceId: "dev-1", tier: "pro", issuedAt: 100, expiresAt: 200 }))
      .toString("base64url");
    expect(verify(forged, signed.signature)).toBe(false);
  });
});

describe("resolveTier", () => {
  it("active subscription is pro", () => {
    expect(resolveTier(license({ subscriptionActive: true }), NOW).tier).toBe("pro");
  });
  it("within the trial window is trial, after is free", () => {
    const started = NOW - 3 * 86_400_000;
    expect(resolveTier(license({ trialStartedAt: started }), NOW).tier).toBe("trial");
    const expired = NOW - (TRIAL_DAYS + 1) * 86_400_000;
    expect(resolveTier(license({ trialStartedAt: expired }), NOW).tier).toBe("free");
  });
  it("no subscription and no trial is free", () => {
    expect(resolveTier(license(), NOW).tier).toBe("free");
  });
});

describe("buildSignedEntitlement", () => {
  it("signs the resolved tier with an offline-grace expiry in the future", () => {
    const signed = buildSignedEntitlement("dev-1", license({ subscriptionActive: true }), NOW);
    expect(verify(signed.entitlement, signed.signature)).toBe(true);
    const p = JSON.parse(Buffer.from(signed.entitlement, "base64url").toString()) as EntitlementPayload;
    expect(p.tier).toBe("pro");
    expect(p.deviceId).toBe("dev-1");
    expect(p.expiresAt).toBeGreaterThan(p.issuedAt);
  });
});

describe("validateLicenseKey", () => {
  it("accepts OSMO- keys, rejects others", () => {
    expect(validateLicenseKey("osmo-abc123").valid).toBe(true);
    expect(validateLicenseKey("random").valid).toBe(false);
  });
});

describe("quota", () => {
  beforeEach(() => resetStoreForTests());

  it("weekStart buckets to fixed 7-day windows", () => {
    expect(weekStart(NOW)).toBe(NOW - (NOW % (7 * 86_400_000)));
    expect(weekStart(NOW)).toBe(weekStart(NOW + 86_400_000));   // same week
  });

  it("free tier (not unlimited) allows exactly the weekly cap, then denies", () => {
    const store = getStore();
    const dev = store.registerDevice();
    for (let i = 0; i < FREE_DRAFTS_PER_WEEK; i++) {
      expect(checkAndConsume(store, dev.id, NOW, false).allowed).toBe(true);
    }
    const over = checkAndConsume(store, dev.id, NOW, false);
    expect(over.allowed).toBe(false);
    expect(over.remaining).toBe(0);
  });

  it("unlimited (Pro/trial) never consumes the counter", () => {
    const store = getStore();
    const dev = store.registerDevice();
    for (let i = 0; i < FREE_DRAFTS_PER_WEEK + 5; i++) {
      const r = checkAndConsume(store, dev.id, NOW, true);
      expect(r.allowed).toBe(true);
      expect(r.remaining).toBeNull();
    }
  });

  it("the cap resets in a new week", () => {
    const store = getStore();
    const dev = store.registerDevice();
    for (let i = 0; i < FREE_DRAFTS_PER_WEEK; i++) checkAndConsume(store, dev.id, NOW, false);
    expect(checkAndConsume(store, dev.id, NOW, false).allowed).toBe(false);
    const nextWeek = NOW + 7 * 86_400_000;
    expect(checkAndConsume(store, dev.id, nextWeek, false).allowed).toBe(true);
  });
});
