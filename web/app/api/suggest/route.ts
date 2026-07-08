import { NextRequest, NextResponse } from "next/server";
import { resolveDevice } from "@/lib/connections/auth";
import { getAccounts } from "@/lib/accounts/store";
import { resolveTier } from "@/lib/license/entitlement";
import { peekQuotaDurable, consumeQuotaDurable } from "@/lib/license/quota";
import { DEFAULT_MODEL, isModelAllowed, isProduction } from "@/lib/config/runtime";
import { breakerTripped, recordModelCall } from "@/lib/license/spendBreaker";
import { checkSafety } from "@/lib/safety";
import { flag } from "@/lib/config/flags";

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
  // Auth: the Mac app sends its device token. In keyless/dev mode we accept any
  // bearer so the flow is exercisable; in production (OSMO_REQUIRE_AUTH=1) the
  // token is validated against a registered device — a raw "Bearer " prefix is
  // NOT enough, or anyone could burn the server-side Anthropic key.
  const auth = req.headers.get("authorization") ?? "";
  const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  // Resolve the device against the durable store (survives redeploys, so a
  // returning device isn't forced to re-register).
  const device = await resolveDevice(token);
  // Require a valid device token whenever there's a real bill to protect (a key
  // is set) or in production — not only behind an opt-in flag. Otherwise a single
  // unset env var turns this into an open, unmetered Anthropic relay.
  const mustAuth = isProduction() || !!process.env.ANTHROPIC_API_KEY || process.env.OSMO_REQUIRE_AUTH === "1";
  if (mustAuth && !device) {
    return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  }

  // Server-enforced kill-switch — a client-only flag check wouldn't stop a direct
  // caller from burning the key while drafting is meant to be off.
  if (!flag("aiDrafting")) {
    return NextResponse.json({ error: "ai_disabled" }, { status: 503 });
  }

  let body: Body;
  try {
    body = (await req.json()) as Body;
  } catch {
    return NextResponse.json({ error: "bad request" }, { status: 400 });
  }
  const systemCore = body.systemCore ?? "";
  const userTurn = body.userTurn ?? "";
  const model = body.model ?? DEFAULT_MODEL;
  if (!systemCore || !userTurn) {
    return NextResponse.json({ error: "missing prompt" }, { status: 400 });
  }
  // Server owns model selection — a client cannot force an arbitrary (expensive)
  // model onto the server-side key.
  if (!isModelAllowed(model)) {
    return NextResponse.json({ error: "model_not_allowed", model }, { status: 400 });
  }

  // Server-side Safety re-run — the proxy must not be a bypass of the client
  // guardrail. Refusal is a 200 with {refused:true} (never a 4xx) so the client
  // renders the reframe message rather than treating it as an error.
  const safety = checkSafety(userTurn);
  if (!safety.allow) {
    return NextResponse.json({ refused: true, reason: safety.reason });
  }

  const key = process.env.ANTHROPIC_API_KEY;
  if (!key) {
    // Keyless mock — clearly marked so it's never mistaken for the real model.
    return NextResponse.json({ text: mockTakes(userTurn), mock: true });
  }

  // Server-enforced free-tier quota — PEEK before the call (a free device over its
  // weekly cap gets 429). We consume the credit only AFTER a successful draft
  // below, so an upstream failure never burns a draft. Pro/trial are unlimited.
  let unlimited = false;
  if (device) {
    const sub = await getAccounts().subscriptionForDevice(device.id);
    unlimited = resolveTier(sub, Date.now()).tier !== "free";
    const peek = await peekQuotaDurable(getAccounts(), device.id, Date.now(), unlimited);
    if (!peek.allowed) {
      return NextResponse.json(
        { error: "quota_exceeded", remaining: 0 },
        { status: 429, headers: { "x-osmo-drafts-remaining": "0" } },
      );
    }
  }

  // Aggregate spend backstop — before any real call. Once the rolling day/month
  // budget is hit we serve the deterministic mock (clearly marked) instead of
  // burning the key. Alert stands in for paging the operator.
  const breaker = breakerTripped();
  if (breaker.tripped) {
    console.error(`[spend-breaker] tripped: ${breaker.reason} — serving degraded mock`);
    return NextResponse.json({ text: mockTakes(userTurn), mock: true, degraded: breaker.reason });
  }
  recordModelCall();

  const anthropicBody = {
    model,
    max_tokens: 700,
    system: [
      // cache_control marks the (stable, large) psychology core as prompt-cached.
      { type: "text", text: systemCore, cache_control: { type: "ephemeral" } },
    ],
    messages: [{ role: "user", content: userTurn }],
  };

  // Bounded retry + timeout: a transient Anthropic 429/500/529 or a slow response
  // shouldn't become a hard user-facing failure.
  let res: Response;
  try {
    res = await callAnthropic(anthropicBody, key);
  } catch {
    return NextResponse.json({ error: "upstream_timeout" }, { status: 502 }); // no credit consumed
  }
  if (!res.ok) {
    return NextResponse.json({ error: "upstream", status: res.status }, { status: 502 }); // no credit consumed
  }
  const data = (await res.json()) as { content?: { type: string; text?: string }[] };
  const text = (data.content ?? [])
    .filter((b) => b.type === "text")
    .map((b) => b.text ?? "")
    .join("\n")
    .trim();

  // Consume the free-tier credit ONLY now that we have a real draft (consume-on-success).
  let remaining: number | null = null;
  if (device && !unlimited) remaining = await consumeQuotaDurable(getAccounts(), device.id, Date.now());

  // We return only the text; nothing is persisted.
  return remaining === null
    ? NextResponse.json({ text })
    : NextResponse.json({ text }, { headers: { "x-osmo-drafts-remaining": String(remaining) } });
}

const RETRYABLE_STATUS = new Set([429, 500, 502, 503, 529]);

/** POST to Anthropic with a request timeout and bounded exponential-backoff
    retries on transient (429/5xx) statuses and network errors. */
async function callAnthropic(body: unknown, key: string): Promise<Response> {
  const baseMs = Number(process.env.OSMO_ANTHROPIC_RETRY_MS ?? 400);
  const timeoutMs = Number(process.env.OSMO_ANTHROPIC_TIMEOUT_MS ?? 30_000);
  let lastErr: unknown;
  for (let attempt = 0; attempt < 3; attempt++) {
    if (attempt > 0) await new Promise((r) => setTimeout(r, baseMs * 2 ** (attempt - 1)));
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), timeoutMs);
    try {
      const res = await fetch(ANTHROPIC_URL, {
        method: "POST",
        headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json" },
        body: JSON.stringify(body),
        signal: ctrl.signal,
      });
      clearTimeout(timer);
      if (res.ok || !RETRYABLE_STATUS.has(res.status) || attempt === 2) return res;
      await res.arrayBuffer().catch(() => {}); // drain the retryable body before looping
    } catch (e) {
      clearTimeout(timer);
      lastErr = e;
      if (attempt === 2) throw e;
    }
  }
  throw lastErr ?? new Error("anthropic call failed");
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
