-- 031: Sales CRM Phase 2 — automatic contact <-> platform-user detection.
-- APPLIED to Supabase project pqmdtqsscyltykgcwwus on 2026-07-25 as
-- migrations `bespokelms_crm_auto_link_031` + `bespokelms_crm_auto_link_031b`
-- (via the Supabase MCP connector). Trigger behaviour PROVEN live:
-- same-org contact links on insert; a tenant learner's contact does NOT link
-- until its account is promoted+linked (boundary held); junction insert
-- re-matches; system activities written; all test data rolled back.
--
-- When a CRM contact and a platform profile share an email address WITHIN A
-- LEGITIMATE OWNERSHIP BOUNDARY, the contact is linked to the profile
-- (profile_id + auto_email_match) and a 'system' activity is written to the
-- contact's timeline ("Became a platform user").
--
-- The boundary (the controller/processor rule from the CRM proposal, C3):
--   a) the contact's owning organisation IS the profile's organisation, or
--   b) the contact is linked to an account whose tenant-promotion link
--      (crm_accounts.organization_id) is the profile's organisation or an
--      ancestor of it.
-- Database triggers (not an app job) so matching works no matter how a
-- profile or contact comes to exist: seeding, Supabase auth flows, a future
-- admin UI, or the Phase-4 Freshsales import.

create or replace function crm_apply_contact_links(
  p_contact uuid default null,
  p_profile uuid default null,
  p_owning uuid default null
)
returns integer
language sql
security definer
set search_path to 'public'
as $$
  with candidates as (
    select distinct on (c.id)
           c.id as contact_id,
           c.owning_organization_id,
           p.id as profile_id
    from crm_contacts c
    join profiles p on lower(p.email) = lower(c.email)
    where c.profile_id is null
      and c.archived_at is null
      and c.email is not null
      and p.email is not null
      and (p_contact is null or c.id = p_contact)
      and (p_profile is null or p.id = p_profile)
      and (p_owning is null or c.owning_organization_id = p_owning)
      and (
        c.owning_organization_id = p.organization_id
        or exists (
          select 1
          from crm_account_contacts l
          join crm_accounts a on a.id = l.account_id
          where l.contact_id = c.id
            and a.archived_at is null
            and a.organization_id is not null
            and p.organization_id in (select org_and_descendants(a.organization_id))
        )
      )
    order by c.id,
             (p.organization_id = c.owning_organization_id) desc,
             p.created_at asc
  ),
  linked as (
    update crm_contacts c
    set profile_id = cd.profile_id,
        profile_linked_at = now(),
        profile_link_method = 'auto_email_match',
        updated_at = now()
    from candidates cd
    where c.id = cd.contact_id
    returning c.id, c.owning_organization_id
  ),
  logged as (
    insert into crm_activities
      (owning_organization_id, activity_type, subject, body, happened_at, contact_id, source, channel_refs)
    select owning_organization_id,
           'system',
           'Became a platform user',
           'Automatically linked to a platform profile by email match.',
           now(),
           id,
           'auto_link',
           '{}'::jsonb
    from linked
    returning 1
  )
  select count(*)::integer from logged;
$$;

revoke execute on function crm_apply_contact_links(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function crm_apply_contact_links(uuid, uuid, uuid) to service_role;

create or replace function trg_profiles_crm_auto_link()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if new.email is not null then
    perform crm_apply_contact_links(p_profile => new.id);
  end if;
  return new;
end;
$$;

drop trigger if exists profiles_crm_auto_link on profiles;
create trigger profiles_crm_auto_link
  after insert or update of email on profiles
  for each row execute function trg_profiles_crm_auto_link();

create or replace function trg_crm_contacts_auto_link()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if new.email is not null and new.profile_id is null then
    perform crm_apply_contact_links(p_contact => new.id);
  end if;
  return new;
end;
$$;

drop trigger if exists crm_contacts_auto_link on crm_contacts;
create trigger crm_contacts_auto_link
  after insert or update of email on crm_contacts
  for each row execute function trg_crm_contacts_auto_link();

-- 031b: the boundary can WIDEN after a contact exists (an account gets
-- promoted to a tenant, or a contact gets linked to a promoted account),
-- so those events re-run the matcher too.

create or replace function trg_crm_account_contacts_auto_link()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  perform crm_apply_contact_links(p_contact => new.contact_id);
  return new;
end;
$$;

drop trigger if exists crm_account_contacts_auto_link on crm_account_contacts;
create trigger crm_account_contacts_auto_link
  after insert on crm_account_contacts
  for each row execute function trg_crm_account_contacts_auto_link();

create or replace function trg_crm_accounts_auto_link()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if new.organization_id is not null then
    perform crm_apply_contact_links(p_owning => new.owning_organization_id);
  end if;
  return new;
end;
$$;

drop trigger if exists crm_accounts_auto_link on crm_accounts;
create trigger crm_accounts_auto_link
  after insert or update of organization_id on crm_accounts
  for each row execute function trg_crm_accounts_auto_link();

-- Backfill: link anything that already matches.
select crm_apply_contact_links();
