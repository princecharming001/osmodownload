# Osmo — Production Deploy (public release)

The Mac app is fully built. For public users, the **backend must be hosted** — a
downloaded app talks to `OsmoBackend.base` (`https://api.leftonread.in` in Release
builds; `localhost:3000` only in Debug). Until the backend is live at that host,
downloaded apps fall back to mock/demo mode.

## 1. Get the code to GitHub
The Osmo repo has no remote. Render deploys from a Git repo, so push it (private):
```
gh repo create osmo-backend --private --source=. --push   # or push just web/
```
(Only `web/` is deployed; `rootDir: web` in `render.yaml` handles that.)

## 2. Create the Render service
- Render → New → Blueprint → pick this repo → it reads `render.yaml`.
- One **web service** (`osmo-backend`), persistent instance (NOT serverless — the
  sync uses in-memory state + SSE).

## 3. Set the secrets (Render dashboard → Environment)
All are `sync:false` in `render.yaml` (never in git). **Bold = launch-blocking.**
- **`ANTHROPIC_API_KEY`** — no AI drafting / Ask without it. THE critical one.
- **`OSMO_LICENSE_PRIVATE_D`, `OSMO_LICENSE_PUBLIC_X`** — entitlement signing keypair; must be stable forever (changing them invalidates every issued license).
- `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` — accounts/subscriptions persistence (else in-memory, lost on redeploy).
- `UNIPILE_DSN`, `UNIPILE_API_KEY` — LinkedIn/WhatsApp/Instagram.
- `GOOGLE_CLIENT_ID/SECRET`, `SLACK_CLIENT_ID/SECRET`, `X_CLIENT_ID/SECRET` — connections.
- `RESEND_API_KEY` — magic-link + notification email.
- `EXA_API_KEY` — enrichment. `OSMO_WEBHOOK_SECRET` — Unipile webhook verify.
- (Stripe omitted — launching free-first.)

## 4. Map the domain
Render → Settings → Custom Domain → `api.leftonread.in`; add the CNAME it gives you
at your DNS. `PUBLIC_URL` + `X_REDIRECT_URI` in `render.yaml` already point here.

## 5. Update OAuth redirect URIs (in each provider's app)
- **Google:** `https://api.leftonread.in/api/oauth/google/callback`
- **Slack:** `https://api.leftonread.in/api/oauth/slack/callback`
- **X:** `https://api.leftonread.in/api/oauth/x/callback` (add alongside the 127.0.0.1 one)

## 6. Verify, then ship the app
- `curl https://api.leftonread.in/api/suggest` returns `keyless:false` (key wired).
- Cut the notarized app (`scripts/release.sh` → `publish-appcast.sh`) — the Release
  build points at the host automatically. Existing 0.2.1 users auto-update.

## Known follow-ups (not launch-blocking if free-first, single instance)
- **Stripe** checkout/webhook are stubs — real paid billing is a follow-up.
- **In-memory sync + SSE** = one instance only; state resets on redeploy. Horizontal
  scale / persistence needs a Postgres migration.
