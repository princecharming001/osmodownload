// POST /api/enrich/person {name, linkedinHandle, hints} — build a public
// profile bundle for one person: LinkedIn (Unipile) + web mentions (Exa).
// The Mac app persists the result locally; this route holds no state beyond
// a per-device rate window. Keys never leave the server.

import { AuthError, requireDevice, unauthorized } from "@/lib/connections/auth";
import { enrichPerson, type EnrichRequest } from "@/lib/enrich/person";
import { rateLimit } from "@/lib/rateLimit";

// Enrichment fans out to two paid upstreams, so a person-page-flipping spree
// must not turn into an API bill. Uses the shared rate-limit substrate.
const WINDOW_MS = 60_000;
const MAX_PER_WINDOW = 10;

// Re-exported so existing tests that reset the enrich limiter keep working.
export { resetRateLimitForTests } from "@/lib/rateLimit";

export async function POST(req: Request): Promise<Response> {
  try {
    const device = requireDevice(req);
    const body = await req.json().catch(() => ({})) as Partial<EnrichRequest>;
    const name = (body.name ?? "").trim().slice(0, 200);
    if (!name) {
      return Response.json({ error: "name required" }, { status: 400 });
    }
    if (!rateLimit(`enrich:${device.id}`, MAX_PER_WINDOW, WINDOW_MS).ok) {
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
