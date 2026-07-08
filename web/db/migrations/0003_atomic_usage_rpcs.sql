-- Atomic free-tier quota counter ops (race-safe; replaces a JS read-modify-write
-- that could lose updates / be bypassed under concurrency). Applied to the live
-- DB via the Supabase MCP; recorded here so a fresh apply reproduces it.

create or replace function osmo_bump_usage(p_device_id text, p_week_start bigint)
returns integer language plpgsql as $$
declare new_count integer;
begin
  insert into osmo_usage (device_id, week_start, count)
    values (p_device_id, p_week_start, 1)
  on conflict (device_id) do update
    set count = case when osmo_usage.week_start = p_week_start then osmo_usage.count + 1 else 1 end,
        week_start = p_week_start
  returning count into new_count;
  return new_count;
end $$;

create or replace function osmo_refund_usage(p_device_id text, p_week_start bigint)
returns integer language plpgsql as $$
declare new_count integer;
begin
  update osmo_usage set count = greatest(0, count - 1)
    where device_id = p_device_id and week_start = p_week_start
  returning count into new_count;
  return coalesce(new_count, 0);
end $$;
