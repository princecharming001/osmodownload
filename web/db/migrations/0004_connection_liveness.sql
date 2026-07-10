-- 0004_connection_liveness — sync/verify timestamps on connections. Feeds the
-- Connections page's "synced 2m ago" subtitle: last_sync_at is stamped when
-- rows for the connection are appended (webhook message / backfill completion),
-- last_verified_at when a liveness check (GET /api/accounts?verify=1) ran.
--
-- Idempotent.

alter table osmo_connections add column if not exists last_sync_at timestamptz;
alter table osmo_connections add column if not exists last_verified_at timestamptz;
