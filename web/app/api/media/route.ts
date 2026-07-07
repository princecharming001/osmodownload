// GET /api/media?platform=<p>&messageRef=<id>&attachmentRef=<ref>&mime=<mime?>
// The binary proxy for attachment bytes — the Mac app never holds a Gmail
// access token, a Slack bearer token, or the Unipile tenant key, so every
// fetch of real media bytes routes through here with the device's own auth.
// Verifies the device actually has a connection for `platform` before
// touching any provider; mock mode (or no live connection) returns a
// placeholder image rather than erroring, so the UI always has something to
// render.

import { AuthError, requireDevice, unauthorized } from "@/lib/connections/auth";
import { getStore } from "@/lib/connections/memoryStore";
import type { Platform } from "@/lib/connections/types";
import { getUnipile, isLiveUnipile } from "@/lib/unipile/client";

const MAX_BYTES = 25_000_000;

// A tiny valid 1x1 transparent PNG — mock mode / no-live-connection fallback.
const PLACEHOLDER_PNG = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
  "base64",
);

function placeholder(): Response {
  return new Response(PLACEHOLDER_PNG, {
    headers: { "content-type": "image/png", "cache-control": "no-store" },
  });
}

function binaryResponse(bytes: Buffer, mime: string | undefined): Response {
  if (bytes.byteLength > MAX_BYTES) return Response.json({ error: "too large" }, { status: 413 });
  return new Response(bytes, {
    headers: {
      "content-type": mime || "application/octet-stream",
      "cache-control": "private, max-age=86400",
    },
  });
}

export async function GET(req: Request): Promise<Response> {
  try {
    const device = requireDevice(req);
    const url = new URL(req.url);
    const platform = url.searchParams.get("platform") as Platform | null;
    const messageRef = url.searchParams.get("messageRef");
    const attachmentRef = url.searchParams.get("attachmentRef");
    const mime = url.searchParams.get("mime") ?? undefined;
    if (!platform || !messageRef || !attachmentRef) {
      return Response.json({ error: "missing params" }, { status: 400 });
    }

    const store = getStore();
    // The device must actually have a connection for this platform — a
    // request for a platform it never connected gets no data, live or mock.
    const connection = store.connections(device.id).find((c) => c.platform === platform);

    if (platform === "gmail") {
      const tokens = store.oauthTokens(device.id, "gmail") as { access_token?: string } | null;
      if (!connection || !tokens?.access_token) return placeholder();
      const res = await fetch(
        `https://gmail.googleapis.com/gmail/v1/users/me/messages/${encodeURIComponent(messageRef)}/attachments/${encodeURIComponent(attachmentRef)}`,
        { headers: { Authorization: `Bearer ${tokens.access_token}` } },
      );
      if (!res.ok) return Response.json({ error: "fetch failed" }, { status: 502 });
      const json = (await res.json()) as { data?: string };
      if (!json.data) return Response.json({ error: "no data" }, { status: 404 });
      return binaryResponse(Buffer.from(json.data, "base64url"), mime);
    }

    if (platform === "slack") {
      const tokens = store.oauthTokens(device.id, "slack") as { access_token?: string } | null;
      if (!connection || !tokens?.access_token) return placeholder();
      let target: URL;
      try {
        target = new URL(attachmentRef);
      } catch {
        return Response.json({ error: "bad ref" }, { status: 400 });
      }
      // SSRF guard: attachmentRef is a Slack `url_private` we stored verbatim
      // at backfill time — refuse to fetch anything that isn't actually
      // Slack's own file host, however that value got here.
      if (target.hostname !== "files.slack.com") {
        return Response.json({ error: "untrusted host" }, { status: 400 });
      }
      const res = await fetch(target.toString(), {
        headers: { Authorization: `Bearer ${tokens.access_token}` },
      });
      if (!res.ok) return Response.json({ error: "fetch failed" }, { status: 502 });
      const len = Number(res.headers.get("content-length") ?? "0");
      if (len > MAX_BYTES) return Response.json({ error: "too large" }, { status: 413 });
      return new Response(res.body, {
        headers: {
          "content-type": mime || res.headers.get("content-type") || "application/octet-stream",
          "cache-control": "private, max-age=86400",
        },
      });
    }

    // Unipile-backed platforms (linkedin/whatsapp/instagram).
    if (!connection || !isLiveUnipile()) return placeholder();
    const bytes = await getUnipile().downloadAttachment(connection.id, messageRef, attachmentRef);
    if (!bytes) return Response.json({ error: "not found" }, { status: 404 });
    return binaryResponse(bytes, mime);
  } catch (e) {
    if (e instanceof AuthError) return unauthorized();
    throw e;
  }
}
