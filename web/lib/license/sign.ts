// Signs entitlement payloads with an Ed25519 key so the Mac app can trust a
// tier WITHOUT trusting its own local files. The app bundles the matching
// PUBLIC key and verifies the signature; only this server holds the private
// key, so a user editing the cached entitlement just invalidates the signature
// and drops to Free. The private key never leaves the server.
//
// Keys come from env (OSMO_LICENSE_PRIVATE_D / OSMO_LICENSE_PUBLIC_X, the JWK
// `d`/`x` fields, base64url). A committed DEV keypair is the fallback so the
// whole flow runs locally before real keys exist — DEV ONLY, never ship it as
// production signing material (swap both env vars + the app's bundled public
// key for launch).

import crypto from "node:crypto";

/** DEV-ONLY Ed25519 keypair (generated for local testing). Replace via env in
    production. The app's bundled public key must match OSMO_LICENSE_PUBLIC_X. */
export const DEV_PUBLIC_X = "4Y5MSU2cbOXlRE91mcLFmYtT1jfj6_b7tpvDynKkljI";
const DEV_PRIVATE_D = "sEbPIOa3at3s_HAcgRlUPoNx1CXONwFdlzb0ICXN94c";

export interface EntitlementPayload {
  v: number;
  deviceId: string;
  tier: "free" | "trial" | "pro";
  issuedAt: number;        // epoch seconds
  expiresAt: number;       // epoch seconds — offline-grace horizon
  trialEndsAt?: number;    // epoch seconds, when on trial
  trialStartedAt?: number; // epoch seconds — present once a trial has EVER been used,
                           // so the app can hide "start trial" for a lapsed trialer
}

export interface SignedEntitlement {
  /** base64url of the payload JSON — the exact bytes the signature covers. */
  entitlement: string;
  /** base64url of the Ed25519 signature. */
  signature: string;
}

function privateKeyObject(): crypto.KeyObject {
  const d = process.env.OSMO_LICENSE_PRIVATE_D ?? DEV_PRIVATE_D;
  const x = process.env.OSMO_LICENSE_PUBLIC_X ?? DEV_PUBLIC_X;
  return crypto.createPrivateKey({ key: { kty: "OKP", crv: "Ed25519", d, x }, format: "jwk" });
}

/** The public key the app should be bundling — surfaced so a /health or debug
    route can confirm the app/server halves match. */
export function publicKeyX(): string {
  return process.env.OSMO_LICENSE_PUBLIC_X ?? DEV_PUBLIC_X;
}

export function signEntitlement(payload: EntitlementPayload): SignedEntitlement {
  const json = JSON.stringify(payload);
  const bytes = Buffer.from(json, "utf8");
  const signature = crypto.sign(null, bytes, privateKeyObject());
  return {
    entitlement: bytes.toString("base64url"),
    signature: signature.toString("base64url"),
  };
}
