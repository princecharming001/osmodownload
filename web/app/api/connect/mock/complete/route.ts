// POST /api/connect/mock/complete {linkId} — the mock wizard's "Authorize".
// Mirrors the Unipile notify path: resolve link → create connection → seed
// backfill → publish events. 404 when the platform is live-configured.

import { getStore } from "@/lib/connections/memoryStore";
import { completeMockConnect } from "@/lib/unipile/mock";
import { isLiveUnipile } from "@/lib/unipile/client";
import { isLiveOAuth } from "@/lib/oauth/providers";
import { isProduction } from "@/lib/config/runtime";
import { readJsonObject } from "@/lib/http";

export async function POST(req: Request): Promise<Response> {
  // Mock connect wizard — unreachable in production.
  if (isProduction()) return Response.json({ error: "not found" }, { status: 404 });
  const body = await readJsonObject(req);
  const linkId = body.linkId as string | undefined;
  if (!linkId) return Response.json({ error: "linkId required" }, { status: 400 });

  const store = getStore();
  const peek = store.peekPendingLink(linkId);
  if (!peek) return Response.json({ error: "unknown link" }, { status: 404 });

  // Mock completion only exists for platforms running in mock mode.
  const live = (peek.platform === "gmail" || peek.platform === "slack")
    ? isLiveOAuth(peek.platform)
    : isLiveUnipile();
  if (live) return Response.json({ error: "not found" }, { status: 404 });

  const link = store.resolvePendingLink(linkId);   // single-use
  if (!link) return Response.json({ error: "link already used" }, { status: 409 });

  const connection = completeMockConnect(link.deviceId, link.platform);
  return Response.json({ ok: true, connectionId: connection.id, platform: connection.platform });
}
