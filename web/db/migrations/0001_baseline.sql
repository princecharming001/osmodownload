-- 0001_baseline — the CURRENT implicit accounts/billing schema, captured as a
-- tracked migration. These five tables were previously hand-created in Supabase;
-- this file is now the source of truth. Columns mirror EXACTLY what
-- lib/accounts/store.ts (SupabaseAccountsStore) reads and writes.
--
-- Idempotent: safe to re-run. Service role bypasses RLS; anon/publishable keys
-- are locked out (RLS enabled, no policies).

create extension if not exists pgcrypto;

create table if not exists osmo_users (
  id            uuid primary key default gen_random_uuid(),
  email         text not null unique,
  apple_user_id text unique,
  display_name  text,
  created_at    timestamptz not null default now()
);

create table if not exists osmo_devices (
  id           text primary key,                 -- "dev-<uuid>"
  token        text not null,
  user_id      uuid references osmo_users(id) on delete set null,
  label        text,
  created_at   timestamptz not null default now(),
  last_seen_at timestamptz
);
create index if not exists osmo_devices_user_id_idx on osmo_devices(user_id);
create index if not exists osmo_devices_token_idx on osmo_devices(token);

create table if not exists osmo_subscriptions (
  id                     uuid not null default gen_random_uuid(),
  owner_type             text not null check (owner_type in ('user','device')),
  owner_id               text not null,          -- user uuid (as text) or device id
  license_key            text,
  subscription_active    boolean not null default false,
  plan                   text,
  trial_started_at       timestamptz,
  stripe_customer_id     text,
  stripe_subscription_id text,
  updated_at             timestamptz not null default now(),
  primary key (owner_type, owner_id)
);

-- Free-tier quota usage (per device, week bucket). week_start is epoch ms.
create table if not exists osmo_usage (
  device_id  text not null,
  week_start bigint not null,
  count      integer not null default 0,
  primary key (device_id, week_start)
);

create table if not exists osmo_magic_links (
  token      text primary key,
  email      text not null,
  expires_at timestamptz not null,
  used       boolean not null default false
);

create table if not exists osmo_web_sessions (
  token      text primary key,
  user_id    uuid not null references osmo_users(id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table osmo_users        enable row level security;
alter table osmo_devices      enable row level security;
alter table osmo_subscriptions enable row level security;
alter table osmo_magic_links  enable row level security;
alter table osmo_web_sessions enable row level security;
