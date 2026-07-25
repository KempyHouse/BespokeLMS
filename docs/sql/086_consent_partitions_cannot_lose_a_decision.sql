-- 086: a missing partition must never lose a consent decision.
--
-- WHAT WAS WRONG. consent_records is range-partitioned by month, and
-- ensure_consent_partitions() creates the next few. Nothing ran it. Partitions
-- reach January 2027, and on the 1st of February 2027 every INSERT into the
-- ledger would begin failing with "no partition of relation found for row".
--
-- The failure would not look like an outage. ConsentRuntimeController answers
-- 503 with retry:true, the browser retries once and gives up, and the cookie
-- it already wrote means the visitor's choice still applies perfectly. The
-- website works. The banner works. The only thing that stops is the evidence
-- — which is the entire reason the table exists, and which nobody would miss
-- until an organisation was asked to prove a consent and could not.
--
-- TWO FIXES, because scheduling the job is not enough on its own. A schedule
-- can be turned off, a container can stop, a deploy can drop the scheduler,
-- and the resulting silence looks exactly like everything being fine.
--
--  1. A DEFAULT PARTITION. A row that matches no month now lands there instead
--     of erroring. The decision is recorded. That is the whole point: a
--     slightly misfiled row is recoverable and a lost one is not.
--
--  2. ensure_consent_partitions() now COPES WITH ROWS IN THE DEFAULT. Without
--     this, fix 1 makes things worse rather than better: once the default
--     holds a row for January, PostgreSQL refuses to create the January
--     partition, and the job that was supposed to recover the situation fails
--     forever. So it detaches the default, creates the month, moves the rows
--     that belong in it, and reattaches.
--
-- The failure mode after this migration is "a maintenance job errors and rows
-- are temporarily in the wrong partition". Before it, the failure mode was
-- "a tenant cannot prove what a visitor agreed to".

create table if not exists public.consent_records_default
  partition of public.consent_records default;

create or replace function public.ensure_consent_partitions(months_ahead integer default 3)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  i integer;
  start_date date;
  end_date date;
  part_name text;
  made integer := 0;
  stranded bigint;
begin
  for i in 0..greatest(0, months_ahead) loop
    start_date := date_trunc('month', current_date + (i || ' months')::interval)::date;
    end_date := (start_date + interval '1 month')::date;
    part_name := 'consent_records_' || to_char(start_date, 'YYYY_MM');

    if exists (select 1 from pg_class where relname = part_name) then
      continue;
    end if;

    -- Does the default already hold rows belonging to the month we are about
    -- to create? If it does, PostgreSQL will refuse to attach the new
    -- partition, and refusing is correct — those rows have to go somewhere.
    execute format(
      'select count(*) from public.consent_records_default where occurred_at >= %L and occurred_at < %L',
      start_date, end_date
    ) into stranded;

    if stranded = 0 then
      execute format(
        'create table public.%I partition of public.consent_records for values from (%L) to (%L)',
        part_name, start_date, end_date
      );
      made := made + 1;

      continue;
    end if;

    -- The recovery path. Detach first: a new partition cannot be created
    -- while the default holds rows that would belong to it, and the default
    -- cannot be emptied while it is attached and still the only home for them.
    alter table public.consent_records detach partition public.consent_records_default;

    execute format(
      'create table public.%I partition of public.consent_records for values from (%L) to (%L)',
      part_name, start_date, end_date
    );

    -- Through the parent, so the rows route into the partition that now
    -- exists rather than being written where they already are.
    execute format(
      'insert into public.consent_records select * from public.consent_records_default '
      || 'where occurred_at >= %L and occurred_at < %L',
      start_date, end_date
    );

    execute format(
      'delete from public.consent_records_default where occurred_at >= %L and occurred_at < %L',
      start_date, end_date
    );

    alter table public.consent_records attach partition public.consent_records_default default;

    made := made + 1;

    -- Loud, because reaching this branch means the ledger has been running on
    -- the default partition — which is to say the schedule stopped and nobody
    -- noticed until now.
    raise warning 'consent ledger: recovered % row(s) from the default partition into %', stranded, part_name;
  end loop;

  return made;
end;
$$;

revoke all on function public.ensure_consent_partitions(integer) from public, anon, authenticated;
grant execute on function public.ensure_consent_partitions(integer) to service_role;

/*
 * Is the ledger actually safe right now?
 *
 * The scheduled command asks this after doing its work, so a run that quietly
 * achieves nothing still reports the truth. "The job succeeded" and "the
 * ledger has somewhere to write next month" are different statements, and it
 * is the second one that matters.
 */
create or replace function public.consent_partition_health()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select jsonb_build_object(
    'covered_to', (
      select max(to_date(substring(c.relname from 'consent_records_(\d{4}_\d{2})'), 'YYYY_MM') + interval '1 month' - interval '1 day')::date
        from pg_class c
       where c.relname ~ '^consent_records_\d{4}_\d{2}$'
    ),
    'months_ahead', (
      select greatest(0, (
        extract(year from age(
          coalesce(max(to_date(substring(c.relname from 'consent_records_(\d{4}_\d{2})'), 'YYYY_MM')), current_date),
          date_trunc('month', current_date)::date
        )) * 12
        + extract(month from age(
          coalesce(max(to_date(substring(c.relname from 'consent_records_(\d{4}_\d{2})'), 'YYYY_MM')), current_date),
          date_trunc('month', current_date)::date
        ))
      ))::int
        from pg_class c
       where c.relname ~ '^consent_records_\d{4}_\d{2}$'
    ),
    -- Anything here means a decision was written with no month to hold it.
    -- Not lost, which is the improvement, but it is the alarm.
    'default_rows', (select count(*) from public.consent_records_default)
  );
$$;

revoke all on function public.consent_partition_health() from public, anon, authenticated;
grant execute on function public.consent_partition_health() to service_role;
