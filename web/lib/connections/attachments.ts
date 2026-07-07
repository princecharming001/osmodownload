// Shared attachment-kind inference — every platform reader (Gmail/Slack/
// Unipile) funnels through this so "an image is an image" regardless of the
// provider's own vocabulary for it.

import type { AttachmentKind } from "./types";

/** Attachment `type`/mime → our coarse kind. `type` may be a provider-specific
    string (Unipile's "img"/"post", Slack's filetype, etc.); `mime` is the
    RFC 2045 mime type when known. Either alone is enough to classify. */
export function kindFromMime(type: string | undefined, mime: string | undefined): AttachmentKind {
  const t = (type ?? "").toLowerCase();
  if (t.includes("post") || t.includes("link") || t.includes("share")) return "link";
  if (t.includes("img") || t.includes("image") || t === "picture" || t === "photo") return "image";
  if (t.includes("video")) return "video";
  if (t.includes("audio") || t.includes("voice")) return "audio";
  if (mime?.startsWith("image/")) return "image";
  if (mime?.startsWith("video/")) return "video";
  if (mime?.startsWith("audio/")) return "audio";
  return "file";
}
