import { describe, it, expect } from "vitest";
import { kindFromMime } from "@/lib/connections/attachments";
import { readAttachments } from "@/lib/unipile/normalize";
import { gmailAttachmentsToWire } from "@/lib/oauth/gmailBackfill";
import { readSlackAttachments } from "@/lib/oauth/slackBackfill";

describe("kindFromMime — shared attachment-kind inference", () => {
  it("classifies by provider type hint", () => {
    expect(kindFromMime("img", undefined)).toBe("image");
    expect(kindFromMime("video", undefined)).toBe("video");
    expect(kindFromMime("voice", undefined)).toBe("audio");
    expect(kindFromMime("post", undefined)).toBe("link");
    expect(kindFromMime("share", undefined)).toBe("link");
  });

  it("falls back to mime type when the type hint is absent/unknown", () => {
    expect(kindFromMime(undefined, "image/png")).toBe("image");
    expect(kindFromMime(undefined, "video/mp4")).toBe("video");
    expect(kindFromMime(undefined, "audio/mpeg")).toBe("audio");
  });

  it("defaults to file when nothing matches", () => {
    expect(kindFromMime(undefined, undefined)).toBe("file");
    expect(kindFromMime("weird-type", "application/pdf")).toBe("file");
  });
});

describe("readAttachments — Unipile message attachment variants", () => {
  it("reads an `attachments` array with id/attachment_id/provider_id variants", () => {
    const out = readAttachments({
      attachments: [
        { id: "a1", type: "img", mimetype: "image/jpeg", file_name: "photo.jpg", file_size: 1024 },
      ],
    });
    expect(out).toEqual([
      { id: "a1", kind: "image", mimeType: "image/jpeg", filename: "photo.jpg",
        sizeBytes: 1024, remoteRef: "a1", url: null, title: null },
    ]);
  });

  it("reads a `files` array (alternate field name)", () => {
    const out = readAttachments({ files: [{ provider_id: "f1", type: "video", size: 500 }] });
    expect(out?.[0]).toMatchObject({ id: "f1", kind: "video", sizeBytes: 500 });
  });

  it("a shared-post/reel maps to kind link with url + title, no remoteRef", () => {
    const out = readAttachments({
      attachments: [{ id: "p1", type: "post", url: "https://instagram.com/p/xyz", title: "A reel" }],
    });
    expect(out?.[0]).toEqual({
      id: "p1", kind: "link", mimeType: null, filename: null, sizeBytes: null,
      remoteRef: null, url: "https://instagram.com/p/xyz", title: "A reel",
    });
  });

  it("skips entries with no usable id, never crashes on a malformed entry", () => {
    const out = readAttachments({ attachments: [{ type: "img" }, { id: "ok", type: "file" }] });
    expect(out?.length).toBe(1);
    expect(out?.[0].id).toBe("ok");
  });

  it("returns undefined for messages with no attachments", () => {
    expect(readAttachments({})).toBeUndefined();
    expect(readAttachments({ attachments: [] })).toBeUndefined();
  });
});

describe("gmailAttachmentsToWire — Gmail attachment metadata → wire rows", () => {
  it("maps attachmentId as both id and remoteRef", () => {
    const out = gmailAttachmentsToWire([
      { attachmentId: "att-1", filename: "invoice.pdf", mimeType: "application/pdf", sizeBytes: 4821 },
    ]);
    expect(out).toEqual([
      { id: "att-1", kind: "file", mimeType: "application/pdf", filename: "invoice.pdf",
        sizeBytes: 4821, remoteRef: "att-1" },
    ]);
  });

  it("classifies an image attachment by mime type", () => {
    const out = gmailAttachmentsToWire([
      { attachmentId: "att-2", filename: "photo.png", mimeType: "image/png", sizeBytes: 900 },
    ]);
    expect(out?.[0].kind).toBe("image");
  });

  it("returns undefined for no attachments", () => {
    expect(gmailAttachmentsToWire([])).toBeUndefined();
  });
});

describe("readSlackAttachments — Slack file shares", () => {
  it("carries url_private as remoteRef (needed to refetch with the bearer token)", () => {
    const out = readSlackAttachments([
      { id: "F1", name: "screenshot.png", mimetype: "image/png", filetype: "png",
        size: 2048, url_private: "https://files.slack.com/files-pri/T1-F1/screenshot.png" },
    ]);
    expect(out).toEqual([{
      id: "F1", kind: "image", mimeType: "image/png", filename: "screenshot.png",
      sizeBytes: 2048, remoteRef: "https://files.slack.com/files-pri/T1-F1/screenshot.png",
    }]);
  });

  it("skips files missing an id or url_private", () => {
    expect(readSlackAttachments([{ name: "no-id.png" }])).toBeUndefined();
    expect(readSlackAttachments([{ id: "F2" }])).toBeUndefined();
  });

  it("returns undefined for no files", () => {
    expect(readSlackAttachments(undefined)).toBeUndefined();
    expect(readSlackAttachments([])).toBeUndefined();
  });
});
