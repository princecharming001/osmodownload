// Feature flags + kill-switches. Server-authoritative: routes enforce these, not
// just the client (a client-only "kill switch" doesn't stop a direct caller).
// Override defaults with OSMO_FLAGS (JSON). Moves behind the signed config
// registry under Phase 2 (D14d); the shape stays the same.

const DEFAULTS: Record<string, boolean> = {
  aiDrafting: true,   // master kill-switch for all model calls
  autodraft: true,    // autodraft-on-arrival
  enrichment: true,   // public-profile lookups
  media: true,        // attachment media pipeline
  webhooks: true,     // realtime webhooks
};

export function getFlags(): Record<string, boolean> {
  let flags = { ...DEFAULTS };
  if (process.env.OSMO_FLAGS) {
    try { flags = { ...flags, ...JSON.parse(process.env.OSMO_FLAGS) }; } catch { /* keep defaults */ }
  }
  return flags;
}

/** A single flag; defaults to on (fail-open for availability) when unspecified. */
export function flag(name: string): boolean {
  const v = getFlags()[name];
  return v === undefined ? true : v;
}
