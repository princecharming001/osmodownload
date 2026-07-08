// Signed config registry (Phase 2 / D14d). A server-delivered, Ed25519-signed
// bundle of VOLATILE config — per-task model ids, thresholds, directives, and
// feature flags — so prompts/models iterate WITHOUT an app update. The byte-stable
// psychology core stays app-bundled; only this volatile layer is remote.
//
// SEPARATE key domain from the entitlement signer (lib/license/sign.ts): a
// distinct dev keypair here, distinct env vars (OSMO_REGISTRY_PRIVATE_D /
// OSMO_REGISTRY_PUBLIC_X). Client fetch→verify→cache→offline-fallback: a kill
// (e.g. aiDrafting=off) requires a VALID signature; on verify failure the client
// uses its last-known-good cache, else the app-bundled defaults.

import crypto from "node:crypto";
import { getFlags } from "./flags";
import { DEFAULT_MODEL, allowedModels } from "./runtime";

// DEV-ONLY registry keypair (distinct from the license signer). Replace via env
// in production; the app bundles the matching OSMO_REGISTRY_PUBLIC_X.
export const DEV_REGISTRY_PUBLIC_X = "oa9gOx8ttY6XoL70D_FjnRXIhRxsYLb68aXm55YZmng";
const DEV_REGISTRY_PRIVATE_D = "V-KJDKB4ylS_pUstY2eaTIS-FqlctM6vzzE9ITgjKXA";

export interface Registry {
  v: number;
  updatedAt: number;                       // epoch seconds
  flags: Record<string, boolean>;
  models: Record<string, string>;          // task → model id (all within the server allowlist)
  thresholds: Record<string, number>;
  directives: Record<string, string>;
}

export interface SignedRegistry { registry: string; signature: string }

function privateKeyObject(): crypto.KeyObject {
  const d = process.env.OSMO_REGISTRY_PRIVATE_D ?? DEV_REGISTRY_PRIVATE_D;
  const x = process.env.OSMO_REGISTRY_PUBLIC_X ?? DEV_REGISTRY_PUBLIC_X;
  return crypto.createPrivateKey({ key: { kty: "OKP", crv: "Ed25519", d, x }, format: "jwk" });
}
export function registryPublicX(): string {
  return process.env.OSMO_REGISTRY_PUBLIC_X ?? DEV_REGISTRY_PUBLIC_X;
}

const TASKS = ["suggest", "judge", "threadIntel", "dossier", "ask", "voicePersona"];

/** The current registry, assembled from server config. Per-task model ids default
    to DEFAULT_MODEL and are constrained to the server allowlist. */
export function buildRegistry(nowSec: number = Math.floor(Date.now() / 1000)): Registry {
  const allow = new Set(allowedModels());
  const models: Record<string, string> = {};
  for (const t of TASKS) {
    const envModel = process.env[`OSMO_MODEL_${t.toUpperCase()}`];
    models[t] = envModel && allow.has(envModel) ? envModel : DEFAULT_MODEL;
  }
  return {
    v: 1,
    updatedAt: nowSec,
    flags: getFlags(),
    models,
    thresholds: {},
    directives: {},
  };
}

export function signRegistry(reg: Registry): SignedRegistry {
  const bytes = Buffer.from(JSON.stringify(reg), "utf8");
  const signature = crypto.sign(null, bytes, privateKeyObject());
  return { registry: bytes.toString("base64url"), signature: signature.toString("base64url") };
}

/** Verify a signed registry against the public key (mirrors the Swift client). */
export function verifyRegistry(signed: SignedRegistry, publicX: string = registryPublicX()): Registry | null {
  try {
    const pub = crypto.createPublicKey({ key: { kty: "OKP", crv: "Ed25519", x: publicX }, format: "jwk" });
    const bytes = Buffer.from(signed.registry, "base64url");
    const ok = crypto.verify(null, bytes, pub, Buffer.from(signed.signature, "base64url"));
    if (!ok) return null;
    return JSON.parse(bytes.toString("utf8")) as Registry;
  } catch {
    return null;
  }
}
