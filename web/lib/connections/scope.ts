// Backfill scope shared by every platform importer (Unipile, Gmail, Slack).
//
//   OSMO_BACKFILL_SCOPE=demo  → the 5 most-recently-active conversations per
//                               platform, messages from the last 15 days — keeps
//                               first imports instant for demos/testing.
//   (default: full)           → the production 60-day deep pull, all threads.
//
// The conversation cap works on the NEWEST-FIRST message stream: the first N
// distinct conversation ids encountered are exactly the N most recently active
// conversations, no separate sorted chat-list call required.

export type BackfillScope = {
  sinceMs: number;
  /** Max conversations per platform (null = unlimited). */
  maxConversations: number | null;
};

export function backfillScope(): BackfillScope {
  if ((process.env.OSMO_BACKFILL_SCOPE ?? "").toLowerCase() === "demo") {
    return { sinceMs: 15 * 24 * 60 * 60 * 1000, maxConversations: 5 };
  }
  // 1 month for now (demo phase) — was 60d. Bump back up when scaling past demos.
  return { sinceMs: 30 * 24 * 60 * 60 * 1000, maxConversations: null };
}

/** A gate over conversation ids: admits ids already seen, and new ids until the
    cap is reached. Feed it a newest-first stream and it selects the `max` most
    recently active conversations. `null` max admits everything. */
export function makeConversationGate(max: number | null): (id: string) => boolean {
  if (max === null) return () => true;
  const allowed = new Set<string>();
  return (id: string) => {
    if (allowed.has(id)) return true;
    if (allowed.size < max) { allowed.add(id); return true; }
    return false;
  };
}
