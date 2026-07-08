# Osmo backend hardening — implementation status

Branch: `backend-hardening` (local only, nothing pushed/deployed). Baseline was
113 tests; now **175 tests green** (`cd web && npm run verify`). 15 commits.

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
