// Shared rate-limit substrate (fixed window). One limiter for every throttled
// route — auth, device registration, enrichment — replacing the ad-hoc per-route
// maps. In-memory / per-process for now; moves to the durable rate_limit_buckets
// store under 0-B so limits hold across restart + instances.

interface Bucket { count: number; resetAt: number; }
const g = globalThis as unknown as { __osmoRate?: Map<string, Bucket> };
function buckets(): Map<string, Bucket> { return (g.__osmoRate ??= new Map()); }

export interface RateResult { ok: boolean; remaining: number; retryAfterSec: number; }

export function rateLimit(key: string, max: number, windowMs: number, now: number = Date.now()): RateResult {
  const map = buckets();
  const b = map.get(key);
  if (!b || b.resetAt <= now) {
    map.set(key, { count: 1, resetAt: now + windowMs });
    return { ok: true, remaining: max - 1, retryAfterSec: 0 };
  }
  if (b.count >= max) {
    return { ok: false, remaining: 0, retryAfterSec: Math.ceil((b.resetAt - now) / 1000) };
  }
  b.count++;
  return { ok: true, remaining: max - b.count, retryAfterSec: 0 };
}

/** Best-effort client IP from proxy headers (Render/Cloudflare set these). */
export function clientIp(req: Request): string {
  const xff = req.headers.get("x-forwarded-for");
  if (xff) return xff.split(",")[0].trim();
  return req.headers.get("x-real-ip") ?? "local";
}

export function tooMany(retryAfterSec: number): Response {
  return new Response(JSON.stringify({ error: "rate_limited", retryAfterSec }), {
    status: 429,
    headers: { "content-type": "application/json", "retry-after": String(retryAfterSec) },
  });
}

export function resetRateLimitForTests(): void { g.__osmoRate = new Map(); }
