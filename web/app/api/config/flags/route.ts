// GET /api/config/flags — remote feature flags + kill-switch. The app fetches
// this on launch and gates features on it, so a misbehaving feature (or a
// runaway AI cost) can be turned off for everyone WITHOUT shipping an update.
// The server ALSO enforces the relevant flags (e.g. /api/suggest checks
// aiDrafting) so a direct caller can't ignore the switch.

import { getFlags } from "@/lib/config/flags";

export const dynamic = "force-dynamic";

export async function GET(): Promise<Response> {
  return Response.json({ flags: getFlags() });
}
