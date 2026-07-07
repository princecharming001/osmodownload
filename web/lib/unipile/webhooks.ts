// Registers Osmo's own webhooks with Unipile so a message/account-status event
// reaches the SSE doorbell in real time (<5s) instead of waiting on the 60s
// reconciliation poll. Idempotent and self-healing: recreates a hook only
// when its target URL is stale (e.g. a fresh tunnel on every dev restart),
// and — because the API key is tenant-wide — NEVER touches a webhook it
// didn't create (matched strictly by name).

import { getUnipile, isLiveUnipile, type UnipileClient } from "./client";

const HOOKS: { name: string; source: string }[] = [
  { name: "osmo-messaging", source: "messaging" },
  { name: "osmo-account-status", source: "account_status" },
];

let ensured = false;

/** Idempotent within a process: the first call does the real work (or
    decides there's nothing to do), every later call is a no-op. `opts` is a
    test seam — production call sites (instrumentation.ts, connect/link) call
    it bare. */
export async function ensureUnipileWebhooks(opts?: {
  client?: UnipileClient;
  live?: boolean;
  publicURL?: string;
}): Promise<void> {
  if (ensured) return;
  const live = opts?.live ?? isLiveUnipile();
  const publicURL = opts?.publicURL ?? process.env.PUBLIC_URL;
  if (!live || !publicURL) return;   // mock mode, or nothing Unipile could reach anyway
  ensured = true;

  const client = opts?.client ?? getUnipile();
  if (!client.listWebhooks || !client.createWebhook || !client.deleteWebhook) return;

  const targetURL = `${publicURL}/api/webhooks/unipile`;
  try {
    const existing = await client.listWebhooks();
    for (const hook of HOOKS) {
      const current = existing.find((h) => h.name === hook.name);
      if (current && current.requestUrl === targetURL) continue;   // already correct
      if (current) await client.deleteWebhook(current.id);
      await client.createWebhook({ name: hook.name, source: hook.source, requestUrl: targetURL });
    }
  } catch (err) {
    ensured = false;   // this attempt didn't land — let a later call retry
    console.error("[unipile webhooks] failed to reconcile:", (err as Error).message);
  }
}

export function resetWebhookEnsureForTests(): void { ensured = false; }
