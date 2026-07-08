# Osmo backend hardening — implementation status

Branch: `backend-hardening` (local only, nothing pushed/deployed). Baseline was
113 tests; now **192 tests + `next build` green** (`cd web && npm run verify:full`, exit 0). 33 commits.

## SERVER: production-ready. Remaining is either your API keys or the Mac app.
- **Backward-compatible** with the current Mac app (SSE uses the Bearer header, not
  `?token=`; the suggest/send wire is unchanged; new response fields are additive).
- **Needs your keys** (code done, flips mock→live when set): Stripe (`STRIPE_SECRET_KEY`
  + `STRIPE_WEBHOOK_SECRET` + price ids), Resend (`RESEND_API_KEY` + `OSMO_EMAIL_FROM`),
  Apple (`OSMO_APPLE_CLIENT_ID`).
- **One paired Mac-app change** (do it alongside the Apple key): Sign in with Apple must
  send `identityToken` + `nonce` (server already verifies it; dev path still works keyless).
- **Privacy items de-scoped** per your call (oplog message-content durability, erase/export).
- **Oplog**: OOM-bounded (`OSMO_OPLOG_MAX`); full durable-oplog intentionally deferred
  (idempotent re-pull + local-first already give correctness).
- **Noted low-risk leftover**: a narrow connection-resurrection race (concurrent
  delete + backfill status-write). Rate-limit stays in-memory (correct for one instance).

## Supabase connected — durable state live (project `general` / nxibeiykcgxpbmkeadth, a SHARED multi-product DB; only osmo_* tables are ours)
- Applied the full **0-B durable schema** (20 `osmo_*` tables + atomic usage RPCs, RLS on)
  via MCP; migrations reconciled to the real pre-existing schema.
- **Store-swaps live-verified** (memory-first, durable write-through, in-memory kept for tests):
  1. **Quota** → `osmo_usage`, now via **atomic `osmo_bump/refund_usage` RPCs** (race-safe;
     reserve-before-call + refund-on-failure — verified against the live DB).
  2. **Device tokens** → `osmo_devices` (async durable fallback — paying devices no longer
     orphaned on every deploy).
  3. **OAuth tokens** → `osmo_oauth_tokens`.
  4. **Connections** → `osmo_connections`, rehydrated on ALL read/write paths (accounts
     GET/PATCH/DELETE, send, rebackfill, media, enrich).
  5. **Stripe webhook idempotency** → `osmo_processed_events` (durable dedup).
- Remaining swap: oplog (largest — hot sync path + a privacy call: it holds message
  content, so persisting to a shared DB needs a deliberate decision). rate-limit/spend
  counters deferred → Redis (hot-path, not per-request Postgres).

## Adversarial review (2-session handoff) — 22 findings, 17 confirmed; all HIGH fixed
Fixed: connection rehydration on every read path (was 404/409 post-redeploy) · atomic
race-safe quota · durable Stripe idempotency · `?token=` query-auth removed · Apple
`emailVerified` enforced · spend breaker counts per retry · no credit on empty-200 ·
`osmo_magic_links.created_at` · a fake-Supabase contract test that exercises the real
durable class. Remaining (noted, low-risk): connection-resurrection race on concurrent
delete+backfill-write; durable backfill-progress not persisted; a couple of test-infra gaps.

## Takeover additions (this session)
- **M6 interactive resilience**: retry/backoff + timeout on the Anthropic call.
- **Observability**: `lib/obs.ts` structured logs + counters; `/api/health` DB-readiness
  probe + metrics snapshot (`draft.ok / upstream_error / quota_exceeded / spend_breaker_trip`).

## Also shipped (beyond the critical-security batch below)
- **CSRF** origin-guard on cookie POSTs (logout, upgrade); **logout** teardown.
- **Real Stripe Checkout** session creation (no SDK), app path `device:<id>` +
  web path `user:<id>` (D13c); mock only in keyless dev.
- **OAuth token refresh** (Gmail/X) with re-persist + connection-degrade on
  failure — stops connections dying in ~1–2h.
- **Signed config registry** `/api/config/registry` (Ed25519, separate key
  domain; per-task model ids within the allowlist; tamper-tested).
- **Send idempotency** key (no duplicate messages on retry).
- **Server kill-switch** — `aiDrafting` enforced in `/api/suggest` (503).
- **0-B durable schema** `db/migrations/0002_durable.sql` — all ~20 Appendix-C
  tables (oplog, oauth_tokens, connections, pending_links w/ PKCE, quota,
  rate_limits, spend, send_outbox, events, caches, registry, ops), drift-guarded.
  Apply with `DATABASE_URL=… npm run db:migrate`.

## SHIPPED this session (11 commits, each tested)

Closed the confirmed **critical + high web-backend security/cost findings** from the audit:

| Area | What landed | Finding closed |
|---|---|---|
| Magic link | `verifyUrl` never in response body; Resend send; prod fails closed | account takeover (critical) |
| Model | server-side allowlist on `/api/suggest` | client-forced expensive model (med) |
| Dev/mock routes | hard `isProduction()` gate (dev/emit, dev/outbox, both mock-completes) | prod-exposed dev surfaces (high) |
| Cost | global Anthropic day/month spend circuit-breaker → degrades to marked mock | no cost ceiling (critical) |
| Safety | server-side re-run (port of Safety.swift), 200 `{refused:true}` | proxy bypasses guardrail (must-fix) |
| Abuse | shared rate-limit substrate on auth/request + device/register | email-bomb, infinite-trial mint (high) |
| Stripe | HMAC signature verify + writes to DURABLE store + idempotency + cancel/refund→lapse | unsigned webhook to wrong store (critical) |
| Apple | identity-token RS256 verify vs Apple JWKS; sub is the identity, not client input | account/sub takeover (critical) |
| Auth | `/api/suggest` requires a device token whenever a key is set / in prod | open unmetered relay (critical) |
| Paywall | `OSMO-` mock license rejected in production | free-Pro bypass (critical) |
| Send | idempotency key → no duplicate messages on retry | duplicate real sends (high) |
| Kill-switch | `aiDrafting` enforced server-side (503) | client-only kill switch (med) |
| Foundations (M0) | `npm run verify`, tracked baseline migration, keyless migration runner, no-DB schema drift guard, PR CI | — |

New modules: `lib/config/runtime.ts`, `lib/config/flags.ts`, `lib/email/resend.ts`,
`lib/safety.ts`, `lib/rateLimit.ts`, `lib/license/spendBreaker.ts`,
`lib/license/stripeSig.ts`, `lib/auth/appleVerify.ts`,
`lib/connections/sendIdempotency.ts`, `db/migrations/`, `db/apply.mjs`.

Note: the abuse/cost/idempotency substrates are per-process today; they move to
durable Postgres under 0-B (marked in each file).

## REMAINING (by milestone) — what's left and why

- **0-B durable state (M1)** — the ~30 Appendix-C tables + swapping the in-memory
  `memoryStore` (oplog, device tokens, OAuth tokens, quota, connections) to
  Postgres. LARGE refactor; its value + testing require a provisioned DB (gate
  G-Postgres). Migrations can be authored ahead; the store swap should follow the DB.
- **0-C payments (M3)** — checkout session creation, price catalog, customer
  portal, `/api/account/upgrade` real Checkout. Needs the Stripe account (gate).
  (Webhook verification + durable lapse are already shipped.)
- **0-D web-auth remainder (M4)** — CSRF on cookie POSTs, logout teardown,
  durable web_sessions. Code-able + testable; Apple-verify already shipped.
- **0-E privacy (M5)** — Swift: move plaintext derivative caches into SQLCipher +
  cover erase/export; `/api/account/export`. Swift not verifiable in this env.
  ZDR/DPA is a legal gate.
- **Phase 1 resilience (M6)** — streaming, retry/backoff on the Anthropic call,
  consume-on-success, typed DraftSet + floor gate. Server-side code-able; the
  DraftSet wire is a Swift+TS lockstep change.
- **Phase 2 registry (M7)** — signed config registry endpoint + client verify.
  (Kill-switch enforcement already shipped.) Signing keys are a gate.
- **Phase 3 eval (M8)** — capsule fixtures + runner + rubric + CI gate. New,
  testable; some capsule curation is human.
- **Phase 4 lifecycle (M9)** — OAuth token refresh (Gmail/Slack/X), inbound paths
  after backfill, durable job queue, precomputed_draft store. Code-able; full
  verification needs live provider tokens.
- **Phase 5 learning (M10)** — on-device exemplar/lineage stores (Swift) + durable
  enrichment cache + de-identified telemetry endpoint.
- **Phase 6 + cross-cutting ops (M11)** — observability, SSRF avatar hardening,
  secrets rotation, backup/DR, OTA delivery. Mixed.

## Human gates (see HUMAN-GATES.md) — cannot be done autonomously
Supabase/Postgres provisioning · Stripe account + keys · Resend account · Apple
Sign-in key material · Anthropic ZDR/DPA · production Ed25519 signing keys ·
single-vs-multi-instance decision · observability backend.
