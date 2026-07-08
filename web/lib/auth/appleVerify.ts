// Sign in with Apple identity-token verification (RS256), no JWT library.
//
// Closes the account-takeover finding: /api/account/link must NOT trust a
// client-supplied appleUserID. The client sends Apple's signed identityToken;
// the server verifies the signature against Apple's JWKS and derives the Apple
// user id from the token's `sub` claim, checking iss/aud/exp (+ optional nonce).

import crypto from "node:crypto";

const APPLE_ISS = "https://appleid.apple.com";
const APPLE_JWKS_URL = "https://appleid.apple.com/auth/keys";

interface Jwk { kid: string; kty: string; n: string; e: string; alg?: string; use?: string; }
let jwksCache: { at: number; keys: Jwk[] } | null = null;

async function appleJwks(now: number): Promise<Jwk[]> {
  if (jwksCache && now - jwksCache.at < 3600_000) return jwksCache.keys;
  const res = await fetch(APPLE_JWKS_URL);
  if (!res.ok) throw new Error("jwks fetch failed");
  const data = (await res.json()) as { keys: Jwk[] };
  jwksCache = { at: now, keys: data.keys };
  return data.keys;
}

function decodeSegment(seg: string): Record<string, unknown> {
  return JSON.parse(Buffer.from(seg, "base64url").toString("utf8"));
}

export interface AppleIdentity { sub: string; email: string | null; emailVerified: boolean; }

export async function verifyAppleIdentityToken(
  token: string,
  opts: { clientId: string; nonce?: string; now?: number },
): Promise<AppleIdentity | null> {
  try {
    const now = opts.now ?? Date.now();
    const [h, p, s] = token.split(".");
    if (!h || !p || !s) return null;

    const header = decodeSegment(h);
    if (header.alg !== "RS256") return null;

    const jwk = (await appleJwks(now)).find((k) => k.kid === header.kid);
    if (!jwk) return null;

    const pub = crypto.createPublicKey({ key: jwk as unknown as crypto.JsonWebKey, format: "jwk" });
    const ok = crypto.verify("RSA-SHA256", Buffer.from(`${h}.${p}`), pub, Buffer.from(s, "base64url"));
    if (!ok) return null;

    const c = decodeSegment(p);
    if (c.iss !== APPLE_ISS) return null;
    const aud = Array.isArray(c.aud) ? c.aud : [c.aud];
    if (!aud.includes(opts.clientId)) return null;
    if (typeof c.exp === "number" && c.exp * 1000 <= now) return null;
    if (opts.nonce) {
      const expected = crypto.createHash("sha256").update(opts.nonce).digest("hex");
      if (c.nonce !== expected && c.nonce !== opts.nonce) return null;
    }
    return {
      sub: String(c.sub),
      email: c.email ? String(c.email) : null,
      emailVerified: c.email_verified === true || c.email_verified === "true",
    };
  } catch {
    return null;
  }
}

export function resetAppleJwksCacheForTests(): void { jwksCache = null; }
