import { NextRequest, NextResponse } from "next/server";
import { resolveDevice } from "@/lib/connections/auth";
import { getAccounts } from "@/lib/accounts/store";
import { resolveTier } from "@/lib/license/entitlement";
import { reserveQuotaDurable, refundQuotaDurable } from "@/lib/license/quota";
import { DEFAULT_MODEL, isModelAllowed, isProduction } from "@/lib/config/runtime";
import { breakerTripped, recordModelCall, ensureSpendLoaded } from "@/lib/license/spendBreaker";
import { checkSafety } from "@/lib/safety";
import { flag } from "@/lib/config/flags";
import { metric, log } from "@/lib/obs";

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
  /** What this call is for. "draft" (default) is a user-facing draft and draws
      from the free-tier weekly draft quota. "decision"/"mine" are BACKGROUND
      relationship-brain calls — they use a separate max_tokens budget and do NOT
      consume the user's manual-draft quota (the brain fires autonomously; it
      must never silently exhaust a user's own drafts). "decision" additionally
      requires the relationshipBrain server flag. */
  purpose?: string;
};

const ANTHROPIC_URL = "https://api.anthropic.com/v1/messages";

// max_tokens per purpose. Decisions need room for evidence lines; a draft is short.
const MAX_TOKENS_BY_PURPOSE: Record<string, number> = { draft: 700, decision: 1200, mine: 900 };
// Purposes that are background brain work — NOT billed to the draft quota.
const BACKGROUND_PURPOSES = new Set(["decision", "mine"]);

// Prompt size caps — systemCore/userTurn are CLIENT-SUPPLIED, and every char
// is billed against the server-side key. A multi-megabyte body must die here
// with a 413, not burn tokens (or blow the model's context) upstream. Generous
// vs. real payloads: the psychology core is ~10k chars, a user turn ~1-2k.
const SYSTEM_CORE_MAX_CHARS = 32_000;
const USER_TURN_MAX_CHARS = 8_000;

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

  // The body must be a plain JSON object — the valid JSON values `null`, `[]`,
  // `"str"` etc. would otherwise crash the property reads below (500).
  const parsed = (await req.json().catch(() => null)) as unknown;
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    return NextResponse.json({ error: "bad request" }, { status: 400 });
  }
  const body = parsed as Body;
  const systemCore = typeof body.systemCore === "string" ? body.systemCore : "";
  const userTurn = typeof body.userTurn === "string" ? body.userTurn : "";
  const model = typeof body.model === "string" ? body.model : DEFAULT_MODEL;
  const purpose = typeof body.purpose === "string" ? body.purpose : "draft";
  const isBackground = BACKGROUND_PURPOSES.has(purpose);
  const maxTokens = MAX_TOKENS_BY_PURPOSE[purpose] ?? MAX_TOKENS_BY_PURPOSE.draft;
  if (!systemCore || !userTurn) {
    return NextResponse.json({ error: "missing prompt" }, { status: 400 });
  }
  // The relationship-brain decision lane has its OWN server kill-switch, default
  // OFF, independent of the aiDrafting master switch — so the brain stays dark in
  // production until deliberately turned on, even where drafting is live.
  if (purpose === "decision" && !flag("relationshipBrain")) {
    return NextResponse.json({ error: "brain_disabled" }, { status: 503 });
  }
  if (systemCore.length > SYSTEM_CORE_MAX_CHARS || userTurn.length > USER_TURN_MAX_CHARS) {
    return NextResponse.json({ error: "prompt_too_large" }, { status: 413 });
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

  // Free-tier quota: compute Pro/trial (unlimited) up front; we RESERVE the credit
  // atomically right before the model call (race-safe) and refund it if the call
  // fails — so an upstream failure never burns a draft AND concurrent requests
  // can't exceed the weekly cap.
  let unlimited = false;
  if (device) {
    const sub = await getAccounts().subscriptionForDevice(device.id);
    unlimited = resolveTier(sub, Date.now()).tier !== "free";
  }

  // Aggregate spend backstop — before any real call. Once the rolling day/month
  // budget is hit we serve the deterministic mock (clearly marked) instead of
  // burning the key. Alert stands in for paging the operator. Rehydrate the
  // durable counters first so a redeploy doesn't reset the cap.
  await ensureSpendLoaded();
  const breaker = breakerTripped();
  if (breaker.tripped) {
    metric("draft.spend_breaker_trip");
    log("error", "spend_breaker_tripped", { reason: breaker.reason });
    return NextResponse.json({ text: mockTakes(userTurn), mock: true, degraded: breaker.reason });
  }

  // Atomically reserve one free-tier draft (429 if over the weekly cap).
  // Background brain calls (decision/mine) draw from a SEPARATE lane and skip
  // this entirely — the autonomous brain must never spend a user's own manual
  // drafts. The aggregate spend breaker above still bounds total cost.
  let remaining: number | null = null;
  if (device && !isBackground) {
    const reserved = await reserveQuotaDurable(getAccounts(), device.id, Date.now(), unlimited);
    if (!reserved.allowed) {
      metric("draft.quota_exceeded");
      return NextResponse.json(
        { error: "quota_exceeded", remaining: 0 },
        { status: 429, headers: { "x-osmo-drafts-remaining": "0" } },
      );
    }
    remaining = reserved.remaining;
  }
  const refund = async (): Promise<void> => {
    if (device && !unlimited && !isBackground) await refundQuotaDurable(getAccounts(), device.id, Date.now());
  };

  const anthropicBody = {
    model,
    max_tokens: maxTokens,
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
    await refund();
    metric("draft.upstream_error");
    log("error", "anthropic_timeout");
    return NextResponse.json({ error: "upstream_timeout" }, { status: 502 });
  }
  if (!res.ok) {
    await refund();
    metric("draft.upstream_error");
    log("error", "anthropic_upstream", { status: res.status });
    return NextResponse.json({ error: "upstream", status: res.status }, { status: 502 });
  }
  // A 200 whose body isn't the documented shape (truncated JSON, content not
  // an array) must refund + 502 like any other upstream failure — an uncaught
  // res.json() throw here would 500 AND silently burn the reserved draft.
  let text: string;
  try {
    const data = (await res.json()) as { content?: { type: string; text?: string }[] };
    text = (Array.isArray(data?.content) ? data.content : [])
      .filter((b) => b && b.type === "text")
      .map((b) => (typeof b.text === "string" ? b.text : ""))
      .join("\n")
      .trim();
  } catch {
    await refund();
    metric("draft.upstream_error");
    log("error", "anthropic_malformed_response");
    return NextResponse.json({ error: "upstream_malformed" }, { status: 502 });
  }
  if (!text) {
    await refund();
    metric("draft.empty");
    return NextResponse.json({ text: "" }); // successful-but-empty: reservation refunded
  }
  metric("draft.ok");

  // Success — keep the reservation. Nothing is persisted beyond the counter.
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
      recordModelCall(); // every real upstream POST bills — count each attempt, not just the first
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
