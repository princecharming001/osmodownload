# Osmo Backend — REVISED Production Plan (audit-hardened)

Legend for change markers:
- `[KEEP]` original plan element, verified sound — do not rewrite.
- `[FIX]` original plan element that is wrong/incomplete as written — corrected here.
- `[ADD]` net-new element the original plan omitted, required for production.

Every `[FIX]`/`[ADD]` cites the confirmed finding(s) or coverage gap it closes.

---

## PART A — What stays (verified solid; do NOT touch)

- `[KEEP]` **3-tier split**: FACTS deterministic / JUDGMENT→LLM / PERSONALIZATION=retrieval of the user's own sent messages. No fine-tuning.
- `[KEEP]` **Wrap the crown jewel, don't rewrite**: keep the deterministic PLAN spine, the technique catalog, prompt-cache discipline, the identity resolver *algorithm* (union-find + blocked-Levenshtein + rejected-pair memory), autodraft pre-compute, UUIDv5/FTS5 substrate.
- `[KEEP]` **Reasoning pipeline shape** S0 FactBlock (device) → S1 PLAN+triage (device) → S2 typed DraftSet single-shot interactive → S3 deterministic floor gate → [background S4/S5] → S6 deliver+log+promote. The *shape* is right; the resilience/cost/infra details are added below.
- `[KEEP]` **Ed25519-signed config registry** concept (volatile config server-delivered; byte-stable psychology core app-bundled so the prompt cache never cold-starts).
- `[KEEP]` **Retrieval, not fine-tuning**, for voice personalization.

---

## PART B — Corrections to claims the plan makes about ITSELF

- `[FIX] B1 — "Phase 0: Security & durable state" was half-specified.` The elaboration only defined the systemCore/Safety/auth fix; "durable state" was named but never designed. Confirmed: the entire runtime (oplog, device tokens, OAuth tokens, quota/trial counters, connections, pending links) is in-memory on one instance and wiped on every redeploy. Phase 0 is re-scoped into four concrete workstreams (0-A…0-D) below.
- `[FIX] B2 — the MUST-FIX is NOT independently shippable.` "Server owns the canonical systemCore, client sends structured fields" structurally breaks the **6 other LLM call sites** (judge, threadIntel, insight, dossier, ask, voicePersona) that share the same `/api/suggest` verbatim wire, OR leaves their injection/key-burn hole open. Correction: introduce a **task-typed contract** (`task` discriminator + one server-owned canonical core per task) so all 7 sites migrate together. (Coverage rows: drafting #2/#3; finding `unvalidated-model-passthrough`, `suggest-verbatim-core`.)
- `[FIX] B3 — the privacy claim as written is falsifiable.` "Messages live on your Mac … never leave" is contradicted by: (a) the built-but-dormant **E2EE blob sync** that egresses encrypted message blobs off-device (`SyncEngine`/`BlobStore`), whose `CryptoBox` KDF uses a **static shared salt** (not real E2EE); (b) **plaintext LLM-derivative caches** (dossiers/insights/voicePersona JSON) and the entire **attachment-bytes directory** that survive "Erase all data"; (c) **enrichment egress** (name/handle/hints → Unipile + Exa); (d) dependence on **Anthropic upstream retention** (default 30-day) for the "keep none/never train" half. Correction: scope the public claim precisely, add ZDR+DPA, fix erase/export completeness, and do not advertise E2EE multi-device until the KDF + key lifecycle are real. (Findings `plaintext-derivative-caches-survive-erase`, `e2ee-privacy-contradiction`, `voice-dossier-egress`, `enrichment-consent-egress`; critic C1/C2/C15/C16.)
- `[FIX] B4 — "iterate models without OTA" must not mean "client picks the model."` The registry may carry per-task model ids, but the **proxy must enforce a server-side model allowlist**; today `model` is forwarded to Anthropic unvalidated. (Finding `unvalidated-model-passthrough`.)

---

## PART C — Revised phased plan

### PHASE 0 — LAUNCH-BLOCKING. Four parallel workstreams. Nothing paid or public ships until all four land.

#### 0-A · Cost & key protection  *(closes: key-burn, Pro-mint, model passthrough, systemCore injection, infinite-trial spend)*
- `[FIX]` Make device-token auth **mandatory** on `/api/suggest`; delete the `OSMO_REQUIRE_AUTH` opt-out (today unauth = open key relay when the flag is unset). Finding `unauthed-key-burn-when-require-auth-unset`.
- `[FIX]` **Server owns the canonical systemCore per task**; client sends `{task, structuredFields}` only. Server re-runs Safety on goal+intent+transcript. Applies to **all 7 tasks**, not just drafting. Finding `suggest-verbatim-core`, coverage #3.
- `[ADD]` **Server-side model allowlist** at the proxy; reject unknown model ids. Finding `unvalidated-model-passthrough`.
- `[ADD]` **Global Anthropic spend circuit-breaker**: rolling daily+monthly budget; on breach → degrade to deterministic mock + page the operator. No aggregate ceiling exists today. Finding `pro-unlimited-uncapped-anthropic`, critic C11.
- `[ADD]` **Quota keyed per-ACCOUNT, not per-device**, and **meter Pro too** (soft ceiling + alert, not a hard paywall). Finding `pro-unlimited-uncapped-anthropic`, `infinite-trials-open-register`, critic C12.
- `[ADD]` **Rate-limit / proof-of-work on `/api/device/register`**; open unlimited minting today defeats quota+trial. Finding `infinite-trials-open-register`.

#### 0-B · Durable, restart-safe server state  *(closes ~15 findings rooted in "wipe on redeploy")*
- `[ADD]` Move to **durable Postgres (Supabase)**: the per-device **oplog**, **device tokens** (with a `deviceByToken` accessor), **OAuth tokens** (encrypted at rest), **quota/trial counters**, **connection records**, **pending OAuth links**. Findings `device-identity-orphaned-on-redeploy`, `device-auth-inmemory-stampede`, `oplog-oom`, `billguard-ephemeral-store`, media/enrichment durability.
- `[ADD]` **Durable, gap-free, monotonic per-device seq** as the cursor source (today a per-process counter). Define the device recovery contract so a durable backend does **not** force a 401→cursor-reset→full re-pull on every deploy. Coverage sync #6/#7; finding `client-cursor-reset-on-durable-migration`.
- `[ADD]` **Bound oplog memory**: content lives in Postgres, not the heap; add retention/compaction. Fixes the OOM crash-loop on the 512 MB instance. Finding `oplog-oom`.
- `[ADD]` **SSE across instances OR an enforced single-instance guard.** Either add a Postgres/Redis pub-sub doorbell fanout (today a doorbell on instance A never reaches a subscriber on B) or make the one-instance invariant a hard deploy guard. Finding `sse-single-instance-timer-leak`, critic C13.

#### 0-C · Payment / entitlement integrity  *(closes: paywall bypass, split-brain billing, grace never lapses)*
- `[FIX]` **Single source of truth = durable `osmo_subscriptions`.** Route **all** billing writes there. Today the Stripe webhook writes to the *ephemeral* memory store that the entitlement read path never reads. Findings `stripe-cancel-lost-write`, `stripe-webhook-ephemeral`, critic (payments).
- `[ADD]` **Real Stripe**: SDK dependency, `checkout.sessions.create`, plan→price map, customer portal; **webhook signature verification** (`constructEvent`); full lifecycle (created/updated/deleted/past_due) → entitlement, so **cancellation actually lapses** and the 7-day offline grace counts down. Findings `stripe-cancel-lost-write`, `paywall-live-in-prod`.
- `[FIX]` **Remove or hard-gate before any paid launch**: the no-auth `mock-complete` Pro-grant and the `OSMO-` prefix "license". Both persist past the Stripe cutover as live bypasses. Findings `paywall-live-in-prod`, `osmo-prefix-license`.

#### 0-D · Web-auth & account safety  *(closes: account takeover)*
- `[FIX]` **Stop returning the magic-link `verifyUrl` in the API response body**; wire real email (Resend); rate-limit `/api/auth/request`. Today any email = instant web-account takeover. Finding `magic-link-verifyurl-leak`.
- `[FIX]` **Verify the Apple identity JWT** in `/api/account/link` (signature, `aud`, `iss`, nonce); never trust client `appleUserID`/`email`. Today any Apple ID is claimable → subscription theft + victim account purge. Finding `account-link-no-apple-verify`.
- `[ADD]` **CSRF protection** on cookie-authed POSTs (logout, upgrade); server-side session expiry/rotation. Coverage web-auth #6.

### PHASE 1 — Structured DraftSet + floor gate + interactive-path resilience
- `[KEEP]` Typed `DraftSet{takes:[{slant,text,why}]}`, single-shot interactive, deterministic S3 floor gate (present/distinct/length/fact-consistent) + server Safety re-run.
- `[ADD]` **Interactive error taxonomy**: map Anthropic 429/500/529/timeout → bounded retry+backoff; **client timeout**; **streaming** so the user sees tokens, not a dead spinner. Findings `interactive-blocking-nonstreaming`, `no-retries-mock-only-on-urlerror`.
- `[FIX]` **Quota consumed only on success** (roll back on failure); today a failed draft still burns a free credit. Finding `quota-consumed-before-call-no-rollback`.
- `[FIX]` **Never silently serve/persist mock as real.** Label degraded mode in the UI; autodraft must never store `"[mock] …"` as a sendable draft. Finding `mock-masks-outage-autodraft`.

### PHASE 2 — Signed config registry (hardened)
- `[KEEP]` Registry carries volatile config only; byte-stable core stays bundled.
- `[ADD]` **Registry signing-key lifecycle**: this is a *distinct* Ed25519 key domain from the entitlement signer; define generation, rotation, and the client fetch→verify→cache→**offline-fallback** path (which flag values apply on signature failure). Critic C8; finding `registry-third-key-otase`.
- `[FIX]` **Server-side kill-switch enforcement.** `/api/suggest` must actually check `aiDrafting`; today the flag is client-enforced only, so it is not a real kill switch. Coverage ops-flags.

### PHASE 3 — Golden-set eval + privacy log-scrub test as REAL infra
- `[FIX]` The golden set (120–200 capsules) and the log-scrubbing privacy test are the only proofs behind the quality-ceiling and "keep none" claims — **and neither exists**. Build the capsule store, runner, scoring rubric, and CI regression gate; run the log-scrub test in CI. Finding `eval-and-privacy-test-absent`, critic C7.

### PHASE 4 — Background quality gate + connection lifecycle & resilience
- `[KEEP]` S4 generate-2 → judge → S5 conditional repair, background pre-compute only.
- `[FIX]` Run it on a **durable job queue + out-of-request worker** (today backfills are in-request fire-and-forget, lost on restart); **budget-account** the 2–4× multiplier against 0-A. Findings `backfill-fire-and-forget`, `bg-quality-gate-cost-multiplier`.
- `[ADD]` **OAuth token refresh loop** (Gmail/Slack/X); today refresh tokens are captured then discarded, so sends die ~1–2 h after connect. Finding `oauth-never-refreshed`.
- `[ADD]` **Inbound path after backfill** for Gmail/Slack/X (Gmail `watch`/history, Slack Events API, X polling); today every new message on those channels after the one-shot import is permanently dropped. Finding `oauth-no-inbound-after-backfill`.
- `[ADD]` **Resumable, idempotent backfill jobs**; **send idempotency key** (stop duplicate real messages to recipients); **optimistic local echo + server-side send timeout**. Findings `send-no-idempotency-duplicates`, `send-blocks-no-optimistic-echo`, `backfill-restart-loss`.

### PHASE 5 — Retrieval voice exemplars + enrichment cache (the learning loop)
- `[KEEP]` Lineage id per draft; sent/edited → voice exemplar; only de-identified pseudonymous scalars leave the device.
- `[ADD]` Specify the **exemplar store** as a new data model AND the **exact pseudonymous-scalar egress payload+endpoint**, gated by the log-scrub test (Phase 3). Coverage drafting #17.
- `[FIX]` **Durable enrichment cache keyed on a STABLE key** (not the volatile `personID`), per-device isolation, TTL; reconcile with the client's 7-day cache. Findings `enrichment-cache-unstable-key`, critic (enrichment).

### PHASE 6 — Evidence-gated ceiling (only under measured demand)
- `[KEEP]` SituationRead/Decision stages, embeddings, on-device model + redaction.
- `[FIX]` **If E2EE multi-device sync is pursued**: real memory-hard KDF (Argon2id) + per-user random salt + key escrow/recovery/rotation, and a corrected privacy claim. Do not enable the current static-salt implementation. Findings `e2ee-privacy-contradiction`, `sync-cursor-not-persisted`, critic C2.

### CROSS-CUTTING (spans all phases) — Ops, privacy integrity, identity
- `[ADD]` **Observability**: structured logging + metrics + alerting on restart/crash, error rate, Anthropic spend, quota exhaustion, SSE subscriber leaks, webhook/backfill failures. Prerequisite to even *notice* the state-loss events the durability work fixes. Critic C9.
- `[ADD]` **Deploy/rollout**: migration ordering for the new durable stores; graceful drain; enforced instance-count guard. Critic C13.
- `[ADD]` **Secrets rotation runbook** (Anthropic key, OAuth client secrets, webhook secret, both/all Ed25519 signers); note the entitlement-signer ↔ app-bundle coupling. Critic C14. (Committed dev entitlement keypair is low-risk — app trusts only the prod pubkey and fails *safe* to Free — but remove it for hygiene. Refuted finding, downgraded.)
- `[ADD]` **Backup/DR**: PITR for server Postgres; **key-escrow/recovery for the local SQLCipher DB key** (single un-escrowed file today = permanent data loss if lost). Critic C5.
- `[ADD]` **GDPR/CCPA**: data **export/portability** (absent everywhere) + **deletion completeness** across durable stores, server caches, plaintext derivative caches, and the exemplar store. Critic C16; finding `plaintext-derivative-caches-survive-erase`.
- `[ADD]` **Identity coherence for multi-device**: stable Person IDs (not min-contact-UUID), synced merge decisions — required *before* any multi-device sync. Findings `person-id-split-brain`, `rejected-merge-resurrect`, critic C3.
- `[ADD]` **Webhook signature verification** (Unipile, Stripe); **avatar/media SSRF hardening** + streaming size-cap (pre-buffer) . Findings `webhook-no-signature`, `media-buffer-before-cap`, critic C4.

---

## Sequencing rule
Phase 0's launch-blocking workstreams gate any paid/public ship. 0-A and 0-C protect money; 0-B is the foundation ~15 other findings rest on; 0-D protects accounts; 0-E (privacy gate, Appendix D12) gates the public privacy claim. Phases 1–6 proceed as the original plan intended, now on a durable, authed, cost-capped base. Cross-cutting Ops items are not a "phase" — they land incrementally alongside 0-B (observability first, the moment durable state exists to observe).

---

## PART D — Specification appendices (concrete contracts that close every residual gap)

These make the plan implementation-precise. Each item cites the coverage row(s) it closes.

### D0 · Universal endpoint & security conventions (apply to EVERY route)
- **Auth is mandatory on ALL device routes**, not just `/api/suggest` — `/api/media`, `/api/enrich/person`, `/api/sync/*`, `/api/accounts`, `/api/events`, etc. all require a durable device Bearer token (Appendix C). *(closes media #31, enrich #41, sync #11 auth halves)*
- **Remove the `?token=` query fallback.** SSE (which can't set headers) authenticates via a short-lived one-time **stream ticket** minted from the Bearer token and validated once at stream open. *(closes licensing `requireDevice` #24, events #11)*
- **Uniform error taxonomy** every route documents: 400 malformed · 401 auth · 403 ownership · 404 missing · 409 conflict/duplicate · 413 too-large · 422 provider-reject · 429 rate/quota · 502 upstream · 503 degraded.
- **Idempotency:** every mutating provider/webhook op carries an idempotency key or dedups on a natural key; Stripe & Unipile webhook handlers dedup on provider event id. *(closes Stripe #27, Unipile #19/#20, send #10)*
- **Shared durable rate-limit substrate** (Postgres/Redis token buckets keyed by route-class × account|device|ip), applied to ALL routes with per-class limits — replaces every per-process Map (enrich 10/60s, register, auth/request). *(closes global-abuse #48, enrich-limiter #42)*
- **OAuth code-flow callbacks** (google/slack/x) validate the durable single-use `state` (anti-forgery) bound to the pending link; the **PKCE `codeVerifier` is stored durably** in the pending-link row, single-use, consumed on callback. *(closes connect/link #15, google #16, slack #17)*
- **Disconnect** revokes the provider token and writes a tombstone (not just a delete). Invalid-token detection on any provider call marks the connection `degraded` and prompts re-auth. *(closes disconnect #22, token-lifecycle #18)*

### D1 · Per-task LLM contract table (all 7 tasks migrate together) — closes drafting #1–#5, #7, #8, #9
| task | server-owned core | structured output | entitlement | quota | Safety input | fallback |
|---|---|---|---|---|---|---|
| **suggest** | draft core | `DraftSet{takes:[{slant,text,why}]}`, ≥3 takes enforced by floor gate | free-metered | consume-on-success | goal+intent+transcript | deterministic degraded-mode (never `[mock]`-as-real) |
| **judge** | analyze core | `Judge{score:0-10,works[≤3],risks[≤3],alts[{label,text}×2]}` | Pro | 1 credit | draft+intent | deterministic ToneCheck-only, labeled "AI unavailable" |
| **threadIntel** | intel core | `Intel{urgency,action,openQuestion,commitments[≤2],tone,temperature,effort,automated}` | Pro | 1 credit/thread/new-msg (cached) | transcript | `DeterministicIntel` |
| **insight** | — | **retired** (superseded by threadIntel; kept only as deterministic fallback, no LLM call) | — | — | — | `Insight.fallback` |
| **dossier** | dossier core | `Dossier{about,remember[≤5]}` | Pro | 1 credit | profile+transcript | `Dossier.fallback` |
| **ask** | ask core | `Ask{text}` | free-metered | **1 credit (an ask burns a credit)** | question+retrieved-context | "AI unavailable" |
| **voicePersona** | voice core | `VoicePersona{paragraphs[3]}` | Pro | once/250 sent msgs (durable cache) | own sent lines | `VoicePersona.fallback` |

- **D1a · threadIntel FACTS vs JUDGMENT** *(closes #2 field decomposition):* FACTS (deterministic, never overridden) = urgency/deadline (DeadlineDetector), action=pay (MoneyDetector), openQuestion, effort, ball-in-court, read-receipt. JUDGMENT (LLM) = tone, temperature, brief, commitments extraction, automated-inference, action nuance. The LLM may interpret a FACT but never contradict it.
- **D1b · Safety hardening + refusal shape** *(closes #7):* keyword floor becomes a fast pre-filter PLUS a server LLM safety classification (`{allow,category,reason}`) inside every task call. Refusal is returned as `200 {refused:true,category,userMessage}` (never a raw 4xx) so the client renders the reframe.
- **D1c · `count` retired** *(closes #8):* removed from the wire; server derives take-count per task; floor gate enforces min-takes and triggers one bounded repair if under.
- **D1d · Autodraft server enforcement** *(closes #9):* the 30/day cap becomes a durable per-account server counter (`autodraft_budget`); the background worker checks it server-side; client policy is a UX pre-filter only.

### D2 · Client↔server reconciliation contracts — closes #6, #23, #26, #44, #57, #63
- **Draft meter:** server authoritative; every task response returns `x-osmo-quota-remaining`; client mirrors it (server wins on mismatch); the two "15" constants collapse to ONE server value delivered via the Phase-2 registry.
- **Connection phase:** client persists last server-confirmed `connected` phase + timestamp; reconcile distinguishes "server forgot" (now impossible post-0-B) from "user disconnected".
- **Media:** client `MediaStore` gains an LRU eviction cap (default 2 GB) + retry (3× backoff) + offline queue; server media cache (D5) is authoritative.
- **Enrichment:** client keep-last / empty-this-session / force-toast retained; server durable cache (D6) is source of truth; client TTL defers to the server `TTL` header.

### D3 · Realtime / SSE contract — closes #11, #12, #51
- **Versioned event schema** `{v,type: sync.dirty|connection.status|backfill.progress|heartbeat, seq, …}`; **invariant: doorbells carry NO message bodies** (schema-linted).
- **Delivery:** `Last-Event-ID` + redelivery from a durable per-device `event_log` (N-minute retention); reconnect with backoff. **Reconcile-fallback guarantee:** doorbells are best-effort latency optimization; any missed doorbell is recovered by the 60 s reconciliation pull (polling is truth).
- **Transport:** Postgres `LISTEN/NOTIFY` (or Redis) pub-sub fanout across instances; auth via the D0 one-time ticket.

### D4 · Send path — closes #10 (and #43 duplicate-send)
Durable `send_outbox` (idempotency_key PK, account, platform, threadID, text, status, attempts, last_error). Optimistic local echo immediately; worker sends with the idempotency key; provider 422 → `rejected` (reject toast); transient/5xx → backoff retry ≤ N; server-side send timeout; 409 on duplicate key.

### D5 · Media & avatars — closes #31, #32, #33, #34, #54, #55, #56, #57
- **`/api/media` contract:** params `{platform,messageRef,attachmentRef,mime}`; device auth + account owns a connection for `platform` (403 else); 400/404/413/502; **413 enforced from streamed byte-count / `content-length` BEFORE full buffer**; **placeholder 1×1 PNG only for no-connection/mock** ("always render something", `no-store`).
- **Per-provider:** Gmail (`messages/*/attachments`, durable-refreshed token, streamed), Slack (`url_private`, SSRF host allowlist `files.slack.com`, streamed), Unipile (`downloadAttachment` SDK, `isLiveUnipile` gate, 404 on null, tenant key, connection-id ownership).
- **Server media cache:** bytes in object storage keyed by (platform, attachmentRef), TTL, CDN-frontable → survives redeploy; `Cache-Control private max-age=86400`.
- **Avatars:** proxied through the media endpoint with scheme(`https`)+host validation + durable cache; no direct client fetch of arbitrary wire URLs; avatar bytes included in erase/export + E2EE-egress accounting.
- **Client `MediaStore`:** LRU cap + retry + offline queue (D2).

### D6 · Enrichment — closes #41, #42, #43, #44, #45, #46, #60, #61, #62, #63
- **`/api/enrich/person` contract:** device auth; req `{name≤200,linkedinHandle?,hints[≤5]}`; resp `{source: linkedin|web|both|mock|none, profile, facts}`; result-size caps; off the drafting critical path.
- **Cost control:** durable shared limiter (D0) + a **paid-upstream cost breaker** (Unipile+Exa daily/monthly budget → degrade to `source=none` + alert), parallel to the Anthropic breaker (0-A).
- **Exa:** key handling, query from name+hints, `numResults`/contents caps, retry 3× backoff on 429/5xx only.
- **Degradation ladder:** 502 ONLY when a *configured* upstream errored; `source=none` = legitimate emptiness — documented so the client separates outage from empty. *(closes #62)*
- **Mock enrichment:** keyless deterministic mock persists for demo/eval determinism, labeled; golden-set eval (Phase 3) includes enrichment fixtures. *(closes #61)*
- **Consent:** `enrichmentEnabled` local toggle enforced client-side AND the `enrichment` flag carried in the Phase-2 registry, checked server-side before any upstream call. *(closes #45)*
- **Server cache:** durable, key = `hash(name|linkedinHandle|hints)`, per-device isolation, server-owned TTL 7 d, invalidation on manual refresh, size caps; client 7-day cache defers to it. *(closes #44, #46)*
- **Unipile/LinkedIn:** refresh/lifecycle handled; when LinkedIn not connected → `source` falls back to web/none (degradation contract). *(closes #43)*

### D7 · Web accounts & compliance — closes #35, #36, #37, #38, #39, #40, #58
- **`/api/auth/verify`:** single-use token consume + 15-min expiry check; first-login = signup find-or-create; success `303 → /account` + Set-Cookie; expired/invalid `303 → /login?error`.
- **Web session:** durable `web_sessions` table (Appendix C); server-side expiry/rotation; cookie-signing secret in the rotation runbook; multi-instance validation via the table.
- **Pages:** `/account` server-component reads durable subscription tier + linked devices, redirects to `/login` when unauthenticated; `/login` never renders an inline verify link (removed with the response-body leak). *(closes #58, #38)*
- **`/api/account/delete`:** idempotent; multi-store purge (durable + object storage + caches + exemplar store + identity graph) with partial-failure retry + a deletion **audit record**.
- **GDPR export:** `/api/account/export` → signed archive (JSON + media manifest) spanning every durable + net-new store (same store list as deletion); format documented. *(closes #40)*

### D8 · Monetization completeness — closes #25, #28, #29, #30, #52, #53
- **`/api/license/reset`:** build-time removed in live mode, dev-only. *(closes #25, #28)*
- **Trial lifecycle:** 14-day durable start; expiry job downgrades tier→free with UI ladder; abuse-bounded by per-account keying + register throttle. *(closes #29)*
- **Refund→entitlement:** `charge.refunded`/dispute → revoke Pro (added to the 0-C lifecycle map); render.yaml gains `STRIPE_SECRET_KEY`/`STRIPE_WEBHOOK_SECRET`/price ids. *(closes #30)*
- **Promo/referral:** durable `promo_codes` + `redemptions` (code, kind, value, max_uses, used_count, per-account log), single-use enforcement, Stripe coupon at checkout; replaces hardcoded FRIEND/LAUNCH/WELCOME. *(closes #52, #53)*

### D9 · Identity coherence (prerequisite to multi-device) — closes #49
- **Storage:** identity graph + `merge_decision` sets (rejected pairs, confirmed merges) added to the durable + E2EE-synced set (Appendix C).
- **Person-ID stability:** derive person id from a **sticky minted person UUID** persisted on first cluster (not the min-contact-UUID), so out-of-order convergence can't mint two rows; a deterministic merge reconciles duplicates.
- **Reconciliation semantics:** rejected-pair set = monotonic union across devices (a rejection anywhere sticks); confirmed-merge takes precedence and is idempotent; rebuild-on-sync consumes synced decisions BEFORE re-clustering so a rejected pair never resurrects.

### D10 · Ops surfaces & release — closes #47, #48, #64, #65, #66, #67, #68, #69, #21
- **Boot webhook registration:** move Unipile reconciliation out of per-process `instrumentation.ts` into one idempotent migration guarded by a durable advisory lock, so N instances don't each reconcile. *(closes #47)*
- **`/api/health`:** liveness + readiness (readiness checks DB + Anthropic reachability); incident banner served from a durable `status_banner` row (not env), editable without redeploy. *(closes #64)*
- **`/api/version` + update-check:** served from a durable `release_info` table (version/build/downloadURL/notes), editable without redeploy, decoupled from the psychology core and distinct from the volatile config registry. *(closes #65)*
- **`/api/feedback`:** durable `feedback` table; free-text may contain message content → covered by the retention/deletion policy and excluded from the "never leaves your Mac" wording. *(closes #66)*
- **Dev + mock routes** (`/api/dev/emit`, `/api/dev/outbox`, `/api/connect/mock/complete`): hard build-time gate (`OSMO_ENV != production`) removes them from prod regardless of Unipile mode. *(closes #67, #68, #21)*
- **Sparkle OTA delivery:** appcast hosting + EdDSA update-signing key management/rotation (a **third** Ed25519 key domain, named in the runbook) + notarized-DMG distribution + `/download` wiring + a backend `min-app-build` compatibility field so the server can require a minimum client version. *(closes #69, #59)*

### D11 · E2EE multi-device sync — explicit decision — closes #13, #14
- **DECISION:** E2EE multi-device DB sync is **NOT shipped in v1**. The dormant `SyncEngine`/`BlobStore` code is disabled behind a build flag; the static-salt `CryptoBox` is never enabled. The public privacy claim is scoped to single-device accordingly.
- **IF pursued (Phase 6):** per-user isolated blob namespace (auth = account), durable per-user cursors, append-only ciphertext log with LWW conflict semantics matching the on-device store, retention/GC; crypto = **Argon2id KDF + per-user random salt + key escrow/recovery/rotation**; **passphrase provenance** = a user-held recovery key generated on-device, shown once, optionally escrowed to iCloud Keychain — never a static salt or server secret.

### D12 · Privacy launch gate 0-E (operationalized) — closes #50
Add to Phase 0 as launch gate **0-E**: **sign the Anthropic Zero-Data-Retention agreement + DPA and publish the sub-processor disclosure BEFORE the "keep none / never train" claim ships** — an owned, hard gate like 0-A/0-C/0-D. The Phase-3 log-scrub test proves OSMO's own non-retention; ZDR/DPA covers the Anthropic upstream dependency the test cannot.

### D13 · Final field-level specs (closes the last 5 round-2 residuals)
- **D13a · threadIntel cache** *(closes threadIntel):* durable `intel_cache` (Appendix C) keyed by (account, threadID, lastMessageID), cols `{intel JSON, model, computedAt}`; invalidation = a new inbound message changes `lastMessageID` → cache miss → recompute (so no TTL needed); this is a distinct store from `enrichment_cache`.
- **D13b · Exemplar + lineage schema + egress payload** *(closes S6 learning loop):*
  - On-device `draft_lineage` `{lineageId PK, threadID, personID, task, generatedAt, takesShown[], slantChosen, action: sent|edited|discarded, finalText, editDistance}`.
  - On-device `voice_exemplar` (the retrieval index) `{exemplarId, personIdOrGlobal, text, addedAt, sourceLineageId, label: sent|sent-edited}`; v1 retrieval = FTS/BM25 top-k by recency+similarity injected into the draft userTurn (embeddings deferred to Phase 6).
  - **The ONLY thing leaving the device** = `outcome_scalars` `{lineageId(opaque), task, slantChosen, action, editDistanceBucket, latencyBucket, refused:bool}` — no text/names/handles — via `POST /api/telemetry/outcome` (device auth), gated by the Phase-3 log-scrub test; server keeps aggregates only.
- **D13c · `/api/account/upgrade`** *(closes account/upgrade):* replace the 501 stub with a real subscription-mode `checkout.sessions.create` bound to **`client_reference_id = user.id`** (distinct from the app path's device binding) so the Stripe webhook maps a web-initiated subscription to the user; success/cancel → `/account`.
- **D13d · `/api/auth/logout`** *(closes logout):* deletes the `web_sessions` row for the presented cookie and clears the cookie (`Set-Cookie maxAge=0`); CSRF-protected (0-D); idempotent (unknown/expired → 200).
- **D13e · Golden-set eval harness** *(closes eval harness):*
  - `eval_capsule` `{capsuleId, task, inputFields, factBlock, goldReference?, rubricTags[]}`; 120–200 versioned capsules stored in-repo as fixtures + a runner.
  - **Rubric dimensions:** fact-consistency (0/1 **hard gate**), safety-pass (0/1 **hard gate**), voice-match (0–5), goal-fit (0–5), non-tell/anti-AI-tell (0–5); scored by the Haiku judge, human-calibrated on a seed set.
  - **Regression gate (CI, Phase-2 promotion):** a registry/prompt/model change is BLOCKED if either hard gate drops below 100% or if mean voice-match/goal-fit regresses beyond a set delta vs the current production baseline.

### D14 · Final reconciliations (closes the round-3 residuals)
- **D14a · voicePersona vs exemplars** *(closes voicePersona):* the LLM `VoicePersona{paragraphs[3]}` is **purely a user-facing profile** (the "You" view) and is **NOT injected into the draft prompt**. Draft-time voice personalization uses ONLY the `voice_exemplar` retrieval index (D13b). No redundancy: persona = human-readable summary; exemplars = the draft substrate.
- **D14b · Signed entitlement contract** *(closes license/validate):* token = `base64url(JSON{v, deviceId, tier: free|trial|pro, issuedAt, expiresAt=issuedAt+7d, trialEndsAt?, trialStartedAt?})` + Ed25519 signature. Issued by `/api/license/validate`, `/api/trial/start`, `/api/promo/redeem`, `/api/account/link` (all read tier from `osmo_subscriptions`). Client `EntitlementVerifier` accepts iff signature valid against the **bundled prod pubkey** AND `deviceId` matches AND `now < expiresAt`; else → free (**fail-safe**). **Offline grace = the `expiresAt` window**: a cached valid entitlement keeps Pro until `expiresAt`; each successful re-validation slides it +7 d; a cancellation stops the slide so Pro lapses at `expiresAt`.
- **D14c · Media degraded-token → placeholder** *(closes media placeholder):* a **degraded/refresh-failed but owned** connection also degrades to the 1×1 placeholder (`no-store`), NOT a 502 — the "always render something" invariant covers no-connection, mock, AND expired/refresh-failed token. A hard 502 is reserved for an unexpected upstream error on an otherwise-healthy token.
- **D14d · Kill-switch fail semantics + registry store** *(closes config/flags):* the signed config registry has a durable `config_registry` store (Appendix C), served at `/api/config/registry` (replaces `/api/config/flags`). Client verify→cache→fallback: a **kill (e.g. `aiDrafting=off`) requires a VALID signed registry**; on signature/verify failure the client uses the **last-known-good cached** registry, and if none, the **app-bundled defaults** (`aiDrafting` on). The switch fails to last-known-good (availability-preserving) while a kill can only be asserted by an authenticated signature — it cannot be forged or silently dropped.

### D15 · Final reconciliations, round 2 (closes the round-4 residuals)
- **D15a · Background quality-gate result store + worker auth** *(closes background quality gate S4/S5):*
  - Durable idempotent `precomputed_draft` store (Appendix C) keyed by (account, threadID, lastMessageID), holding the pre-computed `DraftSet` + judge verdict + `lineageId`; invalidated on a new inbound (same `lastMessageID`-miss rule as `intel_cache`), so S4/S5 output survives restart and re-runs idempotently.
  - The out-of-request worker authenticates as a **service principal** (not a device Bearer token); it attributes each job to its `account_id` from the durable job row, and **all quota/budget/Safety accounting is keyed to that `account_id`** — identical enforcement to the interactive path, just without a per-request device token.
- **D15b · Entitlement-signer rotation** *(closes entitlement signing):* because the entitlement pubkey is app-bundled, rotation follows the same 3-step transition as the OTA signer, gated on the D10 `min-app-build` field: (1) ship an app release bundling BOTH current and next entitlement pubkeys (the verifier accepts either); (2) once `min-app-build` guarantees the fleet has the new pubkey, the server cuts over to signing with the new key; (3) a later release drops the old pubkey. This makes all three Ed25519 domains (entitlement, registry, OTA) have a concrete rotation procedure.

### D16 · Final reconciliations, round 3 (closes the round-5 residuals)
- **D16a · Prompt-cache across the 7 task cores** *(closes prompt-cache discipline):* all 7 server-owned task cores share a **common cached prefix** — the byte-stable psychology core + method library + AntiTell block — with the `cache_control:ephemeral` breakpoint placed at the END of that shared prefix; per-task differences (output contract, task directives) sit AFTER it, and structured fields live in the volatile userTurn. So the expensive psychology-core prefix stays warm across all 7 tasks (never cold-starts); only a small per-task suffix varies.
- **D16b · Oplog store internals** *(closes oplog store):* `oplog` cols `{account_id, device_id, seq BIGINT, native_key, content_hash, payload JSONB, created_at}`, PK `(device_id, seq)`, unique `(device_id, native_key)` for dedup. Gap-free monotonic seq via a **per-device Postgres advisory lock** (or `SELECT … FOR UPDATE` on a per-device `oplog_seq` counter row) around the insert — NOT a global SEQUENCE (gap-prone) — so concurrent writers serialize per device and seq stays dense.
- **D16c · device→user→sub resolver** *(closes accounts store):* add `devices` `(device_id PK, user_id FK nullable, created_at)` as the devices↔users map. A single `subscriptionForDevice(device_id)` is the sole entitlement read path: effective sub = the linked user's active sub if `user_id` is set, else the device's own (app-path) sub. When a device is both app-purchased (device-bound) and later web-linked (user-bound), the **user-bound sub wins** and the device-bound sub is merged/credited into the user (existing `linkDeviceToUser` merge behavior).
- **D16d · Local DB backup / device-loss DR** *(closes local SQLCipher DR):* v1 explicitly accepts that on-device SQLCipher message data is **not** server-backed (local-first + the privacy claim preclude it) — device loss = local loss BY DESIGN, mitigated by re-ingesting from iMessage/providers on a new Mac. The DB **key** is escrow-recoverable so a Time-Machine-restored DB file is openable. Cross-device restore is the explicit job of the deferred E2EE sync (D11/Phase 6); until then this is a documented, accepted limitation.

### D17 · Final reconciliations, round 4 (closes the round-6 residuals)
- **D17a · voicePersona persistence** *(closes voicePersona):* the persona lives **on-device inside SQLCipher** (moved out of the plaintext `voicePersona.json` that B3 flagged), schema `{paragraphs[3], computedAtSentCount, updatedAt}`, recomputed when the sent-message count advances ≥250; covered by "Erase all data" + GDPR export (D7). It is NOT a server durable table (it's a user-facing profile derived on-device, like `draft_lineage`/`voice_exemplar`), which resolves the server-vs-device ambiguity.
- **D17b · `/api/connect/notify` contract** *(closes connect/notify):* Unipile hosted-auth callback — HMAC-verified against the shared webhook secret (over TLS; secret via header, query only as a deprecated fallback), looks up the single-use `pending_links` row by `name = linkId`, **idempotently** binds `account_id → pending link`, creates the durable `connection`, and publishes a `connection.status` doorbell. Never errors back to Unipile.
- **D17c · `/api/feedback` routing** *(closes feedback):* in addition to the durable `feedback` table, each submission is forwarded to an operator channel via `OSMO_FEEDBACK_WEBHOOK` (Slack/Discord/email) so a report reaches a human; triage = the queryable table + the webhook notification.

### Appendix C · Complete durable data model (Postgres unless noted) — closes #39 and the "durable list omits X" residuals (#2 cache, #36/#39 sessions, #46 enrich, #49 identity, #66 feedback)
`oplog` (D16b: PK (device_id,seq), unique (device_id,native_key), per-device advisory-lock seq, content in DB, retention/compaction) · `devices` (D16c: device_id PK, user_id FK, the devices↔users map) · `device_tokens` (deviceByToken accessor, expiry+rotation) · `oauth_tokens` (encrypted at rest, per account×platform; vault key in rotation runbook) · `quota_counters` (per-account week-bucket) · `trials` (per-account) · `connections` (durable phase, tombstones) · `pending_links` (linkId, PKCE codeVerifier, state, single-use) · `send_outbox` (D4) · `event_log` (D3 redelivery) · `osmo_users` · `osmo_subscriptions` (billing source of truth) · `web_sessions` · `magic_links` · `enrichment_cache` (D6) · `identity_graph` + `merge_decisions` (D9) · `autodraft_budget` (D1d) · `promo_codes` + `redemptions` (D8) · `feedback` (D10) · `release_info` (D10) · `status_banner` (D10) · `rate_limit_buckets` (D0) · `intel_cache` (D13a) · `autodraft_budget` (D1d) · `outcome_aggregates` (D13b, server keeps de-identified scalars only) · `eval_capsule` fixtures + results (D13e) · `config_registry` (D14d, signed volatile config; served at `/api/config/registry`) · `precomputed_draft` (D15a, durable idempotent S4/S5 quality-gate output, keyed account×thread×lastMessageID). **On-device (SQLCipher):** `draft_lineage`, `voice_exemplar` (D13b — never leave the Mac). **Object storage:** media + avatar bytes (D5), export archives (D7).
