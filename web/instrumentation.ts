// Next.js instrumentation hook — runs once per server process at startup.
// Registers Osmo's own Unipile webhooks (a no-op in mock mode or when
// PUBLIC_URL isn't set — nothing Unipile could reach anyway), and starts the
// incremental sync scheduler that keeps Gmail/Slack/X updating without a
// manual "re-import history" tap (a no-op outside a live durable deployment).

export async function register(): Promise<void> {
  if (process.env.NEXT_RUNTIME !== "nodejs") return;
  const { ensureUnipileWebhooks } = await import("./lib/unipile/webhooks");
  await ensureUnipileWebhooks();
  const { startIncrementalSyncScheduler } = await import("./lib/sync/scheduler");
  startIncrementalSyncScheduler();
}
