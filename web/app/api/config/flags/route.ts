// GET /api/config/flags — remote feature flags + kill-switch. The app fetches
// this on launch and gates features on it, so a misbehaving feature (or a
// runaway AI cost) can be turned off for everyone WITHOUT shipping an update.
// Override the defaults with the OSMO_FLAGS env var (JSON).

export const dynamic = "force-dynamic";

const DEFAULTS: Record<string, boolean> = {
  aiDrafting: true,   // master kill-switch for all model calls
  autodraft: true,    // autodraft-on-arrival
  enrichment: true,   // public-profile lookups
  media: true,        // attachment media pipeline
  webhooks: true,     // realtime webhooks
};

export async function GET(): Promise<Response> {
  let flags = { ...DEFAULTS };
  if (process.env.OSMO_FLAGS) {
    try { flags = { ...flags, ...JSON.parse(process.env.OSMO_FLAGS) }; } catch { /* keep defaults */ }
  }
  return Response.json({ flags });
}
