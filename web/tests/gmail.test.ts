import { describe, it, expect } from "vitest";
import { walkParts, automatedSignals, templatedSubject, stripHtml, type GmailPart, type GmailHeader } from "@/lib/oauth/gmailBackfill";

function b64url(s: string): string {
  return Buffer.from(s, "utf-8").toString("base64url");
}

describe("walkParts — Gmail MIME body extraction", () => {
  it("plain-text message: root has no `parts` (root-as-leaf)", () => {
    const payload: GmailPart = {
      mimeType: "text/plain",
      body: { data: b64url("hey, are we still on for friday?") },
    };
    const { text, html, attachments } = walkParts(payload);
    expect(text).toBe("hey, are we still on for friday?");
    expect(html).toBeNull();
    expect(attachments).toEqual([]);
  });

  it("nested multipart/alternative inside multipart/mixed, plus an attachment leaf", () => {
    const payload: GmailPart = {
      mimeType: "multipart/mixed",
      parts: [
        {
          mimeType: "multipart/alternative",
          parts: [
            { mimeType: "text/plain", body: { data: b64url("See attached invoice.") } },
            { mimeType: "text/html", body: { data: b64url("<p>See attached invoice.</p>") } },
          ],
        },
        {
          mimeType: "application/pdf",
          filename: "invoice.pdf",
          body: { attachmentId: "att-123", size: 48213 },
        },
      ],
    };
    const { text, html, attachments } = walkParts(payload);
    expect(text).toBe("See attached invoice.");
    expect(html).toBe("<p>See attached invoice.</p>");
    expect(attachments).toEqual([
      { attachmentId: "att-123", filename: "invoice.pdf", mimeType: "application/pdf", sizeBytes: 48213 },
    ]);
  });

  it("html-only message (no text/plain alternative) falls back via stripHtml", () => {
    const payload: GmailPart = {
      mimeType: "text/html",
      body: { data: b64url("<html><body><h1>50% off</h1><p>Shop now!</p></body></html>") },
    };
    const { text, html } = walkParts(payload);
    expect(text).toBeNull();
    expect(html).not.toBeNull();
    const stripped = stripHtml(html!);
    expect(stripped).toContain("50% off");
    expect(stripped).toContain("Shop now!");
    expect(stripped).not.toContain("<h1>");
  });

  it("first text/plain leaf in document order wins over a later duplicate", () => {
    const payload: GmailPart = {
      mimeType: "multipart/mixed",
      parts: [
        { mimeType: "text/plain", body: { data: b64url("first") } },
        { mimeType: "text/plain", body: { data: b64url("second") } },
      ],
    };
    expect(walkParts(payload).text).toBe("first");
  });
});

describe("automatedSignals — bulk/automated sender detection", () => {
  function headers(pairs: Record<string, string>): GmailHeader[] {
    return Object.entries(pairs).map(([name, value]) => ({ name, value }));
  }

  it("List-Unsubscribe header is decisive", () => {
    expect(automatedSignals(headers({ "List-Unsubscribe": "<mailto:x@y.com>" }), "person@company.com")).toBe(true);
  });

  it("Precedence: bulk is decisive", () => {
    expect(automatedSignals(headers({ Precedence: "bulk" }), "a@b.com")).toBe(true);
  });

  it("List-Id header is decisive", () => {
    expect(automatedSignals(headers({ "List-Id": "newsletter.example.com" }), "a@b.com")).toBe(true);
  });

  it("catches service-y localparts even without List-* headers (the real leak)", () => {
    // The exact class that slipped past the old snippet-only classifier:
    // no List-Unsubscribe, no Precedence — just a service-shaped address.
    expect(automatedSignals([], "instagram.alerts@mail.instagram.com")).toBe(true);
    expect(automatedSignals([], "security-notifications@example.com")).toBe(true);
  });

  it("catches known bulk-sender domains", () => {
    expect(automatedSignals([], "hello@substack.com")).toBe(true);
    expect(automatedSignals([], "campaign@sendgrid.net")).toBe(true);
  });

  it("a real person's email with no automated signals passes through", () => {
    expect(automatedSignals(headers({ Subject: "dinner?" }), "sarah.chen@gmail.com")).toBe(false);
  });

  it("Auto-Submitted (RFC 3834) is decisive — unless explicitly \"no\"", () => {
    expect(automatedSignals(headers({ "Auto-Submitted": "auto-generated" }), "a@b.com")).toBe(true);
    expect(automatedSignals(headers({ "Auto-Submitted": "no" }), "sarah.chen@gmail.com")).toBe(false);
  });

  it("Feedback-ID / X-Auto-Response-Suppress / List-Unsubscribe-Post are decisive", () => {
    expect(automatedSignals(headers({ "Feedback-ID": "camp1:acct:sendgrid" }), "a@b.com")).toBe(true);
    expect(automatedSignals(headers({ "X-Auto-Response-Suppress": "All" }), "a@b.com")).toBe(true);
    expect(automatedSignals(headers({ "List-Unsubscribe-Post": "List-Unsubscribe=One-Click" }), "a@b.com")).toBe(true);
  });

  it("ESP fingerprints: DKIM d= and Return-Path domains suffix-match the ESP list", () => {
    expect(automatedSignals(headers({
      "DKIM-Signature": "v=1; a=rsa-sha256; d=sendgrid.net; s=s1; bh=x;",
    }), "founder@startup.com")).toBe(true);
    expect(automatedSignals(headers({
      "Return-Path": "<bounces+123@em8237.lu.ma>",
    }), "host@somevenue.com")).toBe(true);
    // A first-party DKIM domain is NOT an ESP fingerprint.
    expect(automatedSignals(headers({
      "DKIM-Signature": "v=1; a=rsa-sha256; d=startup.com; s=s1;",
    }), "founder@startup.com")).toBe(false);
  });

  it("sending-infrastructure subdomains trip; bare two-label domains never do", () => {
    expect(automatedSignals([], "poker@updates.pokernight.com")).toBe(true);
    expect(automatedSignals([], "offers@e.retailer.com")).toBe(true);
    expect(automatedSignals([], "somebody@mail.com")).toBe(false);   // real mailbox provider
  });

  it("service localparts match EXACTLY on the collapsed localpart — \"hi\" never swallows \"hillary\"", () => {
    expect(automatedSignals([], "events@pokernight.com")).toBe(true);
    expect(automatedSignals([], "hi@influencerapp.io")).toBe(true);
    expect(automatedSignals([], "re-gist.er@fest.com")).toBe(true);  // collapsed = "register"
    expect(automatedSignals([], "hillary@gmail.com")).toBe(false);
    expect(automatedSignals([], "hillary@somecorp.com")).toBe(false);
  });

  it("catches the two real leaks: templated subjects from corporate senders", () => {
    // The exact fixtures that slipped into "You owe a reply" in v0.3.2.
    expect(automatedSignals([], "poker@pokernightapp.com", "Registration approved for Poker Night")).toBe(true);
    expect(automatedSignals([], "chad@influencerapp.io", "Your influencer chad is ready ✨")).toBe(true);
  });

  it("counter-examples: casual human mail is never flagged by subject shape", () => {
    expect(automatedSignals([], "sarah.chen@gmail.com", "dinner?")).toBe(false);
    expect(automatedSignals([], "maya.friend@gmail.com", "your package arrived lol")).toBe(false);
    // Even from a corporate address, the casual marker vetoes the template match.
    expect(automatedSignals([], "jordan@brightlabs.io", "your package arrived lol")).toBe(false);
    // Templated-looking subject from a personal-mail domain stays human.
    expect(automatedSignals([], "mom.lastname@gmail.com", "Your photos from the lake")).toBe(false);
  });
});

describe("templatedSubject — transactional/marketing subject shapes", () => {
  it("matches anchored template openers and mid-string transactional phrases", () => {
    expect(templatedSubject("Registration approved for Poker Night")).toBe(true);
    expect(templatedSubject("Your influencer chad is ready ✨")).toBe(true);
    expect(templatedSubject("Welcome to Fernwood Health")).toBe(true);
    expect(templatedSubject("Verify your email address")).toBe(true);
    expect(templatedSubject("Action required: update your billing info")).toBe(true);
    expect(templatedSubject("You're invited to Demo Day")).toBe(true);
    expect(templatedSubject("Order #48213 has shipped")).toBe(true);
  });

  it("does not match conversational subjects", () => {
    expect(templatedSubject("dinner?")).toBe(false);
    expect(templatedSubject("Re: that thing you mentioned")).toBe(false);
    expect(templatedSubject("following up from the conference")).toBe(false);
  });

  it("casual markers (lol/haha/omg/??) veto a template match", () => {
    expect(templatedSubject("your package arrived lol")).toBe(false);
    expect(templatedSubject("omg your dog is ready for the show")).toBe(false);
    expect(templatedSubject("your car?? haha")).toBe(false);
  });
});
