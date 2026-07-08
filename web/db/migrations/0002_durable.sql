-- 0002_durable — the 0-B durable state (Appendix C). These tables back the
-- substrates currently held in-memory (oplog, OAuth tokens, quota, connections,
-- rate limits, spend counters, send outbox, caches, registry). Apply once
-- Supabase is provisioned; the store code is then re-pointed here (the app keeps
-- the in-memory fallback for keyless/dev, same pattern as osmo_* accounts).
--
-- Idempotent. Service role bypasses RLS; RLS enabled with no policies.

-- Per-device message oplog (D16b: dense per-device seq via app-level advisory lock).
create table if not exists osmo_oplog (
  device_id    text not null,
  seq          bigint not null,
  native_key   text not null,
  content_hash text not null,
  payload      jsonb not null,
  created_at   timestamptz not null default now(),
  primary key (device_id, seq),
  unique (device_id, native_key)
);
create table if not exists osmo_oplog_seq (
  device_id text primary key,
  next_seq  bigint not null default 1
);

-- Encrypted-at-rest OAuth tokens per (device, platform).
create table if not exists osmo_oauth_tokens (
  device_id   text not null,
  platform    text not null,
  tokens      jsonb not null,
  obtained_at timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  primary key (device_id, platform)
);

-- Connections (durable phase + tombstones).
create table if not exists osmo_connections (
  id               text primary key,
  device_id        text not null,
  platform         text not null,
  status           text not null,
  display_name     text,
  backfill_progress double precision,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index if not exists osmo_connections_device_idx on osmo_connections(device_id);

-- Pending OAuth links with the PKCE verifier (single-use).
create table if not exists osmo_pending_links (
  link_id       text primary key,
  device_id     text not null,
  platform      text not null,
  code_verifier text,
  state         text,
  used          boolean not null default false,
  created_at    timestamptz not null default now(),
  expires_at    timestamptz
);

-- NOTE: quota already has a durable home — the existing osmo_usage table
-- (device_id, week_start bigint, count), created in 0001. The store-swap wires
-- quota to THAT table. A per-account rollup (D2) is a later evolution of it.

-- Shared rate-limit buckets — D0.
create table if not exists osmo_rate_limits (
  bucket_key text primary key,
  count      integer not null default 0,
  reset_at   timestamptz not null
);

-- Global Anthropic spend counters (day/month) — 0-A breaker.
create table if not exists osmo_spend_counters (
  period_key text primary key,   -- e.g. "day:2026-07-08" / "month:2026-07"
  count      integer not null default 0
);

-- Send outbox (idempotency + retry) — D4.
create table if not exists osmo_send_outbox (
  idempotency_key text primary key,
  device_id       text not null,
  platform        text not null,
  thread_id       text not null,
  text            text not null,
  status          text not null default 'pending',
  attempts        integer not null default 0,
  last_error      text,
  message         jsonb,
  created_at      timestamptz not null default now()
);

-- Realtime event log for SSE redelivery (Last-Event-ID) — D3.
create table if not exists osmo_events (
  id         bigserial primary key,
  device_id  text not null,
  seq        bigint not null,
  type       text not null,
  payload    jsonb,
  created_at timestamptz not null default now()
);
create index if not exists osmo_events_device_idx on osmo_events(device_id, id);

-- Webhook/event idempotency (Stripe/Unipile redelivery).
create table if not exists osmo_processed_events (
  event_id   text primary key,
  source     text not null,
  created_at timestamptz not null default now()
);

-- Promo / referral codes — D8.
create table if not exists osmo_promo_codes (
  code       text primary key,
  kind       text not null,           -- trial_extend | discount
  value      integer not null default 0,
  max_uses   integer,
  used_count integer not null default 0
);
create table if not exists osmo_promo_redemptions (
  code       text not null,
  account_id text not null,
  created_at timestamptz not null default now(),
  primary key (code, account_id)
);

-- threadIntel cache — D13a.
create table if not exists osmo_intel_cache (
  account_id      text not null,
  thread_id       text not null,
  last_message_id text not null,
  intel           jsonb not null,
  model           text,
  computed_at     timestamptz not null default now(),
  primary key (account_id, thread_id)
);

-- Enrichment cache (stable key, per-device isolation) — D6.
create table if not exists osmo_enrichment_cache (
  cache_key  text primary key,        -- hash(name|linkedinHandle|hints)
  device_id  text not null,
  source     text not null,
  profile    jsonb,
  facts      jsonb,
  updated_at timestamptz not null default now()
);

-- Background quality-gate precomputed drafts — D15a.
create table if not exists osmo_precomputed_draft (
  account_id      text not null,
  thread_id       text not null,
  last_message_id text not null,
  draftset        jsonb not null,
  lineage_id      text,
  created_at      timestamptz not null default now(),
  primary key (account_id, thread_id)
);

-- Signed config registry persistence — D14d.
create table if not exists osmo_config_registry (
  id         integer primary key default 1 check (id = 1),
  registry   jsonb not null,
  updated_at timestamptz not null default now()
);

-- Ops: incident banner + release info + feedback — D10.
create table if not exists osmo_status_banner (
  id         integer primary key default 1 check (id = 1),
  status     text not null default 'operational',
  message    text,
  updated_at timestamptz not null default now()
);
create table if not exists osmo_release_info (
  id          integer primary key default 1 check (id = 1),
  version     text not null,
  build       integer not null,
  download_url text,
  notes       text,
  min_app_build integer,
  updated_at  timestamptz not null default now()
);
create table if not exists osmo_feedback (
  id         bigserial primary key,
  device_id  text,
  message    text not null,
  meta       jsonb,
  created_at timestamptz not null default now()
);

-- Enable RLS on all of the above (service role bypasses; anon locked out).
do $$
declare t text;
begin
  for t in select unnest(array[
    'osmo_oplog','osmo_oplog_seq','osmo_oauth_tokens','osmo_connections','osmo_pending_links',
    'osmo_rate_limits','osmo_spend_counters','osmo_send_outbox','osmo_events',
    'osmo_processed_events','osmo_promo_codes','osmo_promo_redemptions','osmo_intel_cache',
    'osmo_enrichment_cache','osmo_precomputed_draft','osmo_config_registry','osmo_status_banner',
    'osmo_release_info','osmo_feedback'])
  loop
    execute format('alter table %I enable row level security', t);
  end loop;
end $$;
