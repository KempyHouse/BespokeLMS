-- 082: the consent ledger (CMP phase C2). APPLIED to pqmdtqsscyltykgcwwus.
--
-- APPEND-ONLY. There is no update path and no delete path: a withdrawal is a
-- NEW row that supersedes the last one. A ledger you can edit is not evidence,
-- and the whole commercial argument for owning this rather than renting it is
-- that the tenant can prove what a visitor was shown and what they chose.
--
-- Partitioned monthly. This is the highest-volume table in the platform by an
-- order of magnitude — one row per banner interaction across every tenant
-- site — and retention runs on its own clock, so dropping a partition has to
-- be cheaper than deleting rows.
--
-- WHAT IS DELIBERATELY NOT HERE: the visitor's IP address. A country is
-- derived at collection and the address is discarded. Collecting a full IP
-- solely to prove consent is the classic over-collection trap, and it is what
-- got a major CMP enjoined in Germany.

create type consent_action as enum ('accept_all', 'reject_all', 'save_preferences', 'withdraw', 'renew', 'implied_optout');
create type consent_method as enum ('banner', 'preference_centre', 'api', 'form', 'in_app', 'gpc', 'placeholder_click');

create table public.consent_records (
  id uuid not null default gen_random_uuid(),
  organization_id uuid not null,
  site_id uuid not null,
  -- A pseudonymous anchor generated in the browser. It ties one visitor's
  -- decisions together over time without knowing who they are; it becomes
  -- linked to a person only if they later identify themselves.
  consent_id uuid not null,
  domain text not null,
  occurred_at timestamptz not null default now(),
  action consent_action not null,
  method consent_method not null,
  purposes jsonb not null,
  vendors jsonb,
  banner_config_id uuid,
  -- Kept as a value, not only as a foreign key, so the evidence survives the
  -- config being deleted.
  banner_config_hash text not null,
  policy_version text,
  ruleset consent_ruleset not null,
  locale text not null,
  country text,
  -- Path only; the query string is stripped before storage because it is
  -- where campaign parameters and, too often, personal data live.
  page_path text,
  user_agent_family text,
  expires_at timestamptz not null,
  crm_contact_id uuid,
  profile_id uuid,
  superseded_by uuid,
  created_at timestamptz not null default now(),
  primary key (id, occurred_at)
) partition by range (occurred_at);

create index consent_records_visitor_idx on public.consent_records (organization_id, consent_id, occurred_at desc);
create index consent_records_site_idx on public.consent_records (site_id, occurred_at desc);
create index consent_records_contact_idx on public.consent_records (crm_contact_id) where crm_contact_id is not null;

-- Partitions are created ahead of time by this function, called from the
-- scheduler (php artisan consent:ensure-partitions). A missing partition is a
-- failed INSERT, and a failed INSERT here means a visitor's decision was not
-- recorded — so it runs monthly and always keeps several months in front.
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
begin
  for i in 0..greatest(0, months_ahead) loop
    start_date := date_trunc('month', current_date + (i || ' months')::interval)::date;
    end_date := (start_date + interval '1 month')::date;
    part_name := 'consent_records_' || to_char(start_date, 'YYYY_MM');

    if not exists (select 1 from pg_class where relname = part_name) then
      execute format(
        'create table public.%I partition of public.consent_records for values from (%L) to (%L)',
        part_name, start_date, end_date
      );
      made := made + 1;
    end if;
  end loop;

  return made;
end;
$$;

select public.ensure_consent_partitions(6);

alter table public.consent_records enable row level security;

-- INSERT and SELECT only. No update policy and no delete policy exist, so
-- neither is permitted for anyone going through RLS — the append-only rule is
-- enforced by the absence of a way to break it rather than by a trigger
-- somebody could drop.
create policy consent_records_insert on public.consent_records
  for insert with check (organization_id = auth_org_id());

create policy consent_records_select on public.consent_records
  for select using (organization_id = auth_org_id());
