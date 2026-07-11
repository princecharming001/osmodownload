// sendGmail regressions: the two bugs that shipped blank emails to yourself.
// 1. BODY: the blank header/body separator is structural — a filter(Boolean)
//    once stripped it, so the text became a junk header and Gmail sent an
//    EMPTY body.
// 2. RECIPIENT: "reply to whoever last wrote" addressed the user's own reply
//    back to the user; replies must target the last COUNTERPARTY (and honor
//    their Reply-To).
import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";
import { sendGmail } from "@/lib/oauth/send";

const HDRS = (list: Record<string, string>) =>
  Object.entries(list).map(([name, value]) => ({ name, value }));

function mockGmail(threadMessages: { headers: Record<string, string> }[]) {
  const sent: { raw?: string; threadId?: string }[] = [];
  vi.stubGlobal("fetch", vi.fn(async (url: RequestInfo | URL, init?: RequestInit) => {
    const u = String(url);
    if (u.endsWith("/profile")) {
      return new Response(JSON.stringify({ emailAddress: "anish@example.com" }));
    }
    if (u.includes("/threads/")) {
      return new Response(JSON.stringify({
        messages: threadMessages.map(m => ({ payload: { headers: HDRS(m.headers) } })),
      }));
    }
    if (u.endsWith("/messages/send")) {
      sent.push(JSON.parse(String(init?.body ?? "{}")));
      return new Response(JSON.stringify({ id: "sent-1" }));
    }
    throw new Error(`unexpected fetch ${u}`);
  }));
  return sent;
}

const decodeRaw = (raw: string) =>
  Buffer.from(raw.replace(/-/g, "+").replace(/_/g, "/"), "base64").toString("utf8");

describe("sendGmail", () => {
  beforeEach(() => vi.restoreAllMocks());
  afterEach(() => vi.unstubAllGlobals());

  it("keeps the header/body separator — the body is never blank", async () => {
    const sent = mockGmail([
      { headers: { From: "Madi <madi@x.com>", Subject: "quick question", "Message-ID": "<m1>" } },
    ]);
    await sendGmail({ access_token: "t" }, "thread-1", "sounds good, shoot me a text");
    const mime = decodeRaw(sent[0].raw!);
    const [headerPart, ...bodyParts] = mime.split("\r\n\r\n");
    expect(headerPart).toContain("To: Madi <madi@x.com>");
    expect(bodyParts.join("\r\n\r\n")).toBe("sounds good, shoot me a text");
  });

  it("replies to the last counterparty, never to the user's own reply", async () => {
    const sent = mockGmail([
      { headers: { From: "Madi <madi@x.com>", Subject: "quick question", "Message-ID": "<m1>" } },
      { headers: { From: "Anish Polakala <anish@example.com>", Subject: "Re: quick question", "Message-ID": "<m2>" } },
    ]);
    await sendGmail({ access_token: "t" }, "thread-1", "second reply");
    const mime = decodeRaw(sent[0].raw!);
    expect(mime).toContain("To: Madi <madi@x.com>");
    expect(mime).not.toContain("To: Anish");
    // Threading still references the newest message.
    expect(mime).toContain("In-Reply-To: <m2>");
  });

  it("honors the counterparty's Reply-To over From", async () => {
    const sent = mockGmail([
      { headers: { From: "Newsletter <blast@corp.com>", "Reply-To": "team@corp.com", Subject: "hello", "Message-ID": "<m1>" } },
    ]);
    await sendGmail({ access_token: "t" }, "thread-1", "hi");
    expect(decodeRaw(sent[0].raw!)).toContain("To: team@corp.com");
  });
});
