# HUMAN GATES — steps the implementation CANNOT do autonomously

These require an external account, a payment, a legal signature, infra provisioning,
or a production secret. The code that *uses* each is written and unit-tested against
mocks; the account/agreement/secret is yours to provide. Nothing here is deployed —
per the standing rule, no push/deploy/OTA happens without an explicit "push it now".

## Blocking a paid/public launch (Phase 0)
- [ ] **Anthropic Zero-Data-Retention agreement + DPA + sub-processor disclosure** (0-E). The "keep none / never train" claim must not ship until signed. Legal + Anthropic account.
- [ ] **Stripe account + secrets** (`STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, price ids) (0-C). Real checkout/webhooks stay behind these; code is written against the Stripe API but cannot be exercised live without them.
- [ ] **Resend (or other mail provider) account + verified sender domain** (`RESEND_API_KEY`, `OSMO_EMAIL_FROM`) (0-D). Magic-link email send is coded (`lib/email/resend.ts`); until the key exists, the flow runs in dev mode (link shown locally, never in prod — prod fails closed).
- [ ] **Apple Sign in with Apple key material** (team id, key id, `.p8`, client id) to verify the identity JWT in `/api/account/link` (0-D). Needed to stop account/subscription takeover from a raw `appleUserID`.
- [ ] **Durable Postgres / Supabase instance provisioned + `SUPABASE_URL` + `SUPABASE_SERVICE_ROLE_KEY`** (0-B). The ~30 durable tables (Appendix C) target this; migrations are authored in-repo but must be applied against a real instance.

## Infra / ops decisions (need a human call)
- [ ] **Single-instance guard vs. multi-instance pub/sub** for SSE fanout + oplog (0-B / D3). Choose: keep the enforced single always-on instance, or add Redis/Postgres LISTEN-NOTIFY. Affects render.yaml + the events layer.
- [ ] **Production signing keys** for the three Ed25519 domains — entitlement signer, config-registry signer, Sparkle OTA signer — generation + secure storage + rotation (D14b/D15b, Phase 2, D10).
- [ ] **Observability backend** (log drain / metrics / alerting destination) to wire the emitters into (cross-cutting Ops).
- [ ] **Exa / Unipile budgets** for the paid enrichment upstreams (D6 cost breaker thresholds).

## Release (always human, per standing rule)
- [ ] Any `push`, Render deploy, Sparkle OTA, or GitHub release — explicit per-time "push it now" only.

---
_Last updated by the automated build. Items are checked off only when a human confirms._
