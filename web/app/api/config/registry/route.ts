// GET /api/config/registry — the Ed25519-signed volatile config bundle (Phase 2).
// The app fetches this, verifies the signature against its bundled public key,
// caches it, and applies model ids / thresholds / flags WITHOUT an update.
// Supersedes /api/config/flags (which stays for back-compat).

import { buildRegistry, signRegistry } from "@/lib/config/registry";

export const dynamic = "force-dynamic";

export async function GET(): Promise<Response> {
  return Response.json(signRegistry(buildRegistry()));
}
