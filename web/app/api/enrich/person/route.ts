// POST /api/enrich/person {name, linkedinHandle, hints} — build a public
// profile bundle for one person: LinkedIn (Unipile) + web mentions (Exa).
// The Mac app persists the result locally; this route holds no state beyond
// a per-device rate window. Keys never leave the server.

import { AuthError, requireDevice, unauthorized } from "@/lib/connections/auth";
import { enrichPerson, type EnrichRequest } from "@/lib/enrich/person";

// Sliding-window rate limit: enrichment fans out to two paid upstreams, so a
// person-page-flipping spree must not turn into an API bill. Module-level is
// fine — this is per-process defense, not accounting.
const windows = new Map<string, number[]>();
const WINDOW_MS = 60_000;
const MAX_PER_WINDOW = 10;

function rateLimited(deviceId: string): boolean {
  const now = Date.now();
  const hits = (windows.get(deviceId) ?? []).filter((t) => now - t < WINDOW_MS);
  if (hits.length >= MAX_PER_WINDOW) { windows.set(deviceId, hits); return true; }
  hits.push(now);
  windows.set(deviceId, hits);
  return false;
}

/** Test-only reset (mirrors resetStoreForTests). */
export function resetRateLimitForTests(): void {
  windows.clear();
}

export async function POST(req: Request): Promise<Response> {
  try {
    const device = requireDevice(req);
    const body = await req.json().catch(() => ({})) as Partial<EnrichRequest>;
    const name = (body.name ?? "").trim().slice(0, 200);
    if (!name) {
      return Response.json({ error: "name required" }, { status: 400 });
    }
    if (rateLimited(device.id)) {
      return Response.json({ error: "rate limited" }, { status: 429 });
    }
    const request: EnrichRequest = {
      name,
      linkedinHandle: body.linkedinHandle?.trim().slice(0, 300) || null,
      hints: (body.hints ?? []).slice(0, 5).map((h) => String(h).slice(0, 120)),
    };
    try {
      return Response.json(await enrichPerson(device.id, request));
    } catch {
      return Response.json({ error: "enrichment upstreams unavailable" }, { status: 502 });
    }
  } catch (e) {
    if (e instanceof AuthError) return unauthorized();
    return Response.json({ error: "bad request" }, { status: 400 });
  }
}
