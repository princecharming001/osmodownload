import { NextRequest, NextResponse } from "next/server";

// The thin AI proxy. Holds the Anthropic key server-side (never in the Mac app —
// a shipped binary's key is trivially extractable), marks the psychology core as
// a prompt-cached system block (~90% cheaper reads), and **stores nothing**.
//
// Keyless by default: with no ANTHROPIC_API_KEY set, it returns a deterministic
// mock so the whole stack runs before credentials exist. Drop the key in last.

export const runtime = "nodejs";

type Body = {
  systemCore?: string;
  userTurn?: string;
  count?: number;
  model?: string;
};

const ANTHROPIC_URL = "https://api.anthropic.com/v1/messages";

export async function POST(req: NextRequest) {
  // Auth: the Mac app sends the user's Osmo session token. In keyless/dev mode we
  // accept any bearer so the flow is exercisable; production verifies it here.
  const auth = req.headers.get("authorization") ?? "";
  if (process.env.OSMO_REQUIRE_AUTH === "1" && !auth.startsWith("Bearer ")) {
    return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  }

  let body: Body;
  try {
    body = (await req.json()) as Body;
  } catch {
    return NextResponse.json({ error: "bad request" }, { status: 400 });
  }
  const systemCore = body.systemCore ?? "";
  const userTurn = body.userTurn ?? "";
  const model = body.model ?? "claude-sonnet-5";
  if (!systemCore || !userTurn) {
    return NextResponse.json({ error: "missing prompt" }, { status: 400 });
  }

  const key = process.env.ANTHROPIC_API_KEY;
  if (!key) {
    // Keyless mock — clearly marked so it's never mistaken for the real model.
    return NextResponse.json({ text: mockTakes(userTurn), mock: true });
  }

  const anthropicBody = {
    model,
    max_tokens: 700,
    system: [
      // cache_control marks the (stable, large) psychology core as prompt-cached.
      { type: "text", text: systemCore, cache_control: { type: "ephemeral" } },
    ],
    messages: [{ role: "user", content: userTurn }],
  };

  const res = await fetch(ANTHROPIC_URL, {
    method: "POST",
    headers: {
      "x-api-key": key,
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body: JSON.stringify(anthropicBody),
  });

  if (!res.ok) {
    return NextResponse.json({ error: "upstream", status: res.status }, { status: 502 });
  }
  const data = (await res.json()) as { content?: { type: string; text?: string }[] };
  const text = (data.content ?? [])
    .filter((b) => b.type === "text")
    .map((b) => b.text ?? "")
    .join("\n")
    .trim();
  // We return only the text; nothing is persisted.
  return NextResponse.json({ text });
}

function mockTakes(userTurn: string): string {
  const them = userTurn
    .split("\n")
    .filter((l) => l.startsWith("Them: "))
    .pop();
  const subject = them ? them.replace("Them: ", "").split(" ").slice(0, 4).join(" ") : "that";
  return [
    `[mock] direct reply about ${subject}.`,
    `[mock] a warmer take on ${subject}, with more heart.`,
    `[mock] the lighter version 🙂`,
  ].join("\n");
}

export async function GET() {
  return NextResponse.json({
    ok: true,
    keyless: !process.env.ANTHROPIC_API_KEY,
    note: "POST { systemCore, userTurn, count, model }. Stores nothing.",
  });
}
