-- 083: the numbers the consent overview shows. APPLIED to pqmdtqsscyltykgcwwus.
--
-- Aggregation lives here rather than in PHP because the ledger is the largest
-- table in the platform and will only grow: counting a month of rows over
-- PostgREST would mean pulling them across the wire to count them. It is also
-- the difference between a screen that stays fast at a million rows and one
-- that quietly stops loading.
--
-- SECURITY DEFINER with an explicit organisation argument, and the caller is
-- the application using the service-role key with the organisation taken from
-- the signed-in user. Same rule as everywhere else in this module: the tenant
-- is the controller of these records, so there is no path that returns another
-- organisation's numbers.

create or replace function public.consent_summary(p_org uuid, p_days integer default 30)
returns table (
  decisions bigint,
  accepted_all bigint,
  rejected_all bigint,
  partial bigint,
  withdrawn bigint,
  gpc_signals bigint,
  -- Per-purpose opt-in, which is the number that actually matters to a
  -- marketing team and the one they otherwise guess at.
  purpose_grants jsonb
)
language sql
stable
security definer
set search_path to 'public'
as $$
  with window_rows as (
    select r.action, r.method, r.purposes
      from consent_records r
     where r.organization_id = p_org
       and r.occurred_at >= now() - make_interval(days => greatest(1, least(365, coalesce(p_days, 30))))
  ),
  grants as (
    select key, count(*) filter (where value::boolean) as granted, count(*) as asked
      from window_rows, lateral jsonb_each(purposes)
     group by key
  )
  select
    (select count(*) from window_rows),
    (select count(*) from window_rows where action = 'accept_all'),
    (select count(*) from window_rows where action = 'reject_all'),
    (select count(*) from window_rows where action = 'save_preferences'),
    (select count(*) from window_rows where action = 'withdraw'),
    (select count(*) from window_rows where method = 'gpc'),
    coalesce(
      (select jsonb_object_agg(key, jsonb_build_object('granted', granted, 'asked', asked)) from grants),
      '{}'::jsonb
    );
$$;

revoke all on function public.consent_summary(uuid, integer) from public, anon, authenticated;
grant execute on function public.consent_summary(uuid, integer) to service_role;
