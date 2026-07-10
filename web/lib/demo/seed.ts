// Deterministic demo conversations per platform — the keyless-mode content.
// Fixed native IDs ("demo-li-chat-1", "demo-li-msg-3", …) so repeated connects
// and re-pulls dedup cleanly on both sides (backend oplog dedup index + the
// Mac's deterministic UUIDs). Timestamps are fixed offsets from a stable epoch
// so test assertions are reproducible.

import type { Platform, WireContact, WireMessage, WireThread } from "../connections/types";
import type { RowBundle } from "../connections/memoryStore";

// Stable base so seeded content sorts believably "recent" but deterministically.
const BASE = Date.parse("2026-07-01T09:00:00Z");
const iso = (minutesAgo: number) => new Date(BASE - minutesAgo * 60_000).toISOString();

interface Script {
  short: string;                       // platform id fragment: li, wa, ig, gm, sl, x
  people: { handle: string; name: string }[];
  threads: {
    key: string;                       // fragment: chat-1 …
    withIdx: number;                   // index into people
    turns: { fromMe: boolean; text: string; minutesAgo: number }[];
  }[];
  drip: string[];                      // scripted future inbound texts, per tick
}

const SCRIPTS: Partial<Record<Platform, Script>> = {
  linkedin: {
    short: "li",
    people: [
      { handle: "urn:li:member:8841", name: "Sara Kim" },
      { handle: "urn:li:member:2210", name: "Marcus Bell" },
    ],
    threads: [
      {
        key: "chat-1", withIdx: 0,
        turns: [
          { fromMe: false, text: "Hi! Loved your post on local-first apps. Are you open to a quick chat about the platform team we're building?", minutesAgo: 2880 },
          { fromMe: true, text: "Thanks Sara — sure, happy to hear more. What's the scope of the role?", minutesAgo: 2700 },
          { fromMe: false, text: "We're rebuilding the desktop sync layer. Your Osmo work is exactly the profile. Would Thursday 2pm work for a call?", minutesAgo: 90 },
        ],
      },
      {
        key: "chat-2", withIdx: 1,
        turns: [
          { fromMe: false, text: "Hey — following up on the partnership deck I sent over. Any thoughts?", minutesAgo: 4300 },
          { fromMe: true, text: "It's on my list for this week, will get back to you by Friday.", minutesAgo: 4100 },
        ],
      },
    ],
    drip: [
      "Also — our CTO saw your profile and wants to join the call. Still good for Thursday?",
      "Quick nudge on this when you have a sec :)",
      "We can also do Friday morning if that's easier.",
    ],
  },
  whatsapp: {
    short: "wa",
    people: [
      { handle: "+14155550142", name: "Maya" },
      { handle: "+14155550177", name: "Dad" },
    ],
    threads: [
      {
        key: "chat-1", withIdx: 0,
        turns: [
          { fromMe: false, text: "are we still on for dinner saturday??", minutesAgo: 1500 },
          { fromMe: true, text: "yes! 7 at the usual spot?", minutesAgo: 1450 },
          { fromMe: false, text: "perfect. also I have news 👀", minutesAgo: 60 },
        ],
      },
      {
        key: "chat-2", withIdx: 1,
        turns: [
          { fromMe: false, text: "Call me when you get a chance, nothing urgent", minutesAgo: 5600 },
        ],
      },
    ],
    drip: [
      "ok the news can't wait — I got the job!!",
      "dinner is on me saturday 🎉",
    ],
  },
  instagram: {
    short: "ig",
    people: [{ handle: "chloe.designs", name: "Chloe" }],
    threads: [
      {
        key: "chat-1", withIdx: 0,
        turns: [
          { fromMe: false, text: "your studio setup story was so good! what mic is that?", minutesAgo: 800 },
          { fromMe: true, text: "thanks!! it's the SM7B — worth every penny", minutesAgo: 750 },
          { fromMe: false, text: "ok adding to cart. also — collab on a reel next month?", minutesAgo: 120 },
        ],
      },
    ],
    drip: ["thinking something like 'day in the studio' — you in?"],
  },
  gmail: {
    short: "gm",
    people: [
      { handle: "jordan@brightlabs.io", name: "Jordan Reyes" },
      { handle: "team@vaultbank.com", name: "Vault Bank" },
    ],
    threads: [
      {
        key: "thread-1", withIdx: 0,
        turns: [
          { fromMe: false, text: "Subject: Contract renewal\n\nHi — our annual contract is up at the end of the month. Can we schedule 30 minutes to walk through the renewal terms?", minutesAgo: 2000 },
          { fromMe: true, text: "Happy to — Tuesday or Wednesday afternoon works on my end.", minutesAgo: 1900 },
          { fromMe: false, text: "Tuesday 3pm it is. Sending an invite. One thing to flag: we'd like to discuss expanding seats.", minutesAgo: 240 },
        ],
      },
      {
        key: "thread-2", withIdx: 1,
        turns: [
          { fromMe: false, text: "Subject: Statement ready\n\nYour June statement is ready to view.", minutesAgo: 3000 },
        ],
      },
    ],
    drip: ["Quick addition — our CFO will join the Tuesday call. Agenda attached."],
  },
  slack: {
    short: "sl",
    people: [{ handle: "U0842KAT", name: "Priya (Eng)" }],
    threads: [
      {
        key: "dm-1", withIdx: 0,
        turns: [
          { fromMe: false, text: "hey, did you see the flaky test on CI? it's blocking the release branch", minutesAgo: 400 },
          { fromMe: true, text: "looking now — think it's the timezone fixture again", minutesAgo: 380 },
          { fromMe: false, text: "any luck? release cut is at 5", minutesAgo: 30 },
        ],
      },
    ],
    drip: ["update: I can push the cut to 6 if you need the hour"],
  },
  x: {
    short: "x",
    people: [{ handle: "@byteandbrew", name: "Alex Chen" }],
    threads: [
      {
        key: "dm-1", withIdx: 0,
        turns: [
          { fromMe: false, text: "yo — that thread on Mac sandboxing was great. want to come on the pod?", minutesAgo: 900 },
        ],
      },
    ],
    drip: ["we record thursdays — this week or next work?"],
  },
};

function contactRows(p: Platform, s: Script): WireContact[] {
  return s.people.map(person => ({
    platform: p, handle: person.handle, displayName: person.name, isMe: false,
  }));
}

function threadRows(p: Platform, s: Script): WireThread[] {
  return s.threads.map(t => ({
    platform: p,
    platformThreadID: `demo-${s.short}-${t.key}`,
    title: s.people[t.withIdx].name,
    isGroup: false,
    lastMessageAt: iso(Math.min(...t.turns.map(turn => turn.minutesAgo))),
  }));
}

function messageRows(p: Platform, s: Script): WireMessage[] {
  const out: WireMessage[] = [];
  for (const t of s.threads) {
    t.turns.forEach((turn, i) => {
      out.push({
        platform: p,
        platformMessageID: `demo-${s.short}-${t.key}-msg-${i + 1}`,
        platformThreadID: `demo-${s.short}-${t.key}`,
        senderHandle: turn.fromMe ? null : s.people[t.withIdx].handle,
        isFromMe: turn.fromMe,
        text: turn.text,
        sentAt: iso(turn.minutesAgo),
        readAt: turn.fromMe ? null : iso(Math.max(turn.minutesAgo - 5, 0)),
      });
    });
  }
  return out;
}

/** Full seeded history for a platform (the mock "backfill"). */
export function demoConversations(platform: Platform): RowBundle {
  const s = SCRIPTS[platform];
  if (!s) return {};
  return {
    contacts: contactRows(platform, s),
    threads: threadRows(platform, s),
    messages: messageRows(platform, s),
  };
}

/** A caller-chosen sender for a dev-emit — lets tests drive messages from a
    DISTINCT thread/person (e.g. an automated email address) instead of the
    scripted default. `threadKey` picks/creates the thread; it defaults to a
    slug of the handle so the same sender always lands in the same thread. */
export interface DripSender {
  handle: string;
  name?: string | null;
  threadKey?: string;
}

/** The nth scripted inbound (drip timer / dev-emit). Cycles past the end. */
export function dripMessage(platform: Platform, n: number, customText?: string, sender?: DripSender): RowBundle | null {
  const s = SCRIPTS[platform];
  if (!s || s.threads.length === 0) return null;
  const t = s.threads[0];
  const text = customText ?? s.drip[n % s.drip.length];
  const key = sender
    ? (sender.threadKey ?? sender.handle.toLowerCase().replace(/[^a-z0-9]+/g, "-"))
    : t.key;
  const threadID = `demo-${s.short}-${key}`;
  const handle = sender?.handle ?? s.people[t.withIdx].handle;
  const name = sender ? (sender.name ?? sender.handle) : s.people[t.withIdx].name;
  return {
    // The sender rides as a contact row too, so the app's classifier sees the
    // real handle (for gmail emits that's an email address) — not just a title.
    contacts: [{
      platform, handle, displayName: name, isMe: false,
    }],
    threads: [{
      platform,
      platformThreadID: threadID,
      title: name,
      isGroup: false,
      lastMessageAt: new Date().toISOString(),
    }],
    messages: [{
      platform,
      platformMessageID: `${threadID}-drip-${n}`,
      platformThreadID: threadID,
      senderHandle: handle,
      isFromMe: false,
      text,
      sentAt: new Date().toISOString(),
      readAt: null,
    }],
  };
}

/** Display name for the mock connected account per platform. */
export function demoAccountName(platform: Platform): string {
  switch (platform) {
    case "linkedin": return "You (LinkedIn)";
    case "whatsapp": return "+1 (415) 555-0100";
    case "instagram": return "@you.demo";
    case "gmail": return "you@demo.osmo.app";
    case "slack": return "you @ demo-workspace";
    case "x": return "@you_demo";
    default: return "Demo account";
  }
}
