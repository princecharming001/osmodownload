// Stripe webhook signature verification WITHOUT the Stripe SDK — implements the
// documented scheme: header `stripe-signature: t=<unix>,v1=<hex-hmac>[,v1=...]`,
// where the signed payload is `${t}.${rawBody}` HMAC-SHA256'd with the endpoint
// secret. Rejects stale timestamps (replay) outside the tolerance window.

import crypto from "node:crypto";

export function verifyStripeSignature(
  raw: string,
  header: string | null,
  secret: string,
  nowSec: number = Math.floor(Date.now() / 1000),
  toleranceSec: number = 300,
): boolean {
  if (!header) return false;
  let t: string | undefined;
  const v1s: string[] = [];
  for (const part of header.split(",")) {
    const i = part.indexOf("=");
    if (i < 0) continue;
    const k = part.slice(0, i).trim();
    const v = part.slice(i + 1).trim();
    if (k === "t") t = v;
    else if (k === "v1") v1s.push(v);
  }
  if (!t || v1s.length === 0) return false;
  const ts = Number(t);
  if (!Number.isFinite(ts) || Math.abs(nowSec - ts) > toleranceSec) return false;

  const expected = crypto.createHmac("sha256", secret).update(`${t}.${raw}`).digest("hex");
  const expBuf = Buffer.from(expected);
  return v1s.some((v1) => {
    const got = Buffer.from(v1);
    return got.length === expBuf.length && crypto.timingSafeEqual(got, expBuf);
  });
}
