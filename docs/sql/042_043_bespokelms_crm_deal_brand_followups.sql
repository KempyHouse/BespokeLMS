-- =============================================================================
-- BespokeLMS — Supabase migrations 042 + 043 (applied 2026-07-25)
-- CRM: deal ↔ brand tagging, and follow-up task scheduling.
-- Reference copy of migrations applied to project pqmdtqsscyltykgcwwus:
--   bespokelms_crm_deal_brand_042
--   bespokelms_crm_followups_043
-- =============================================================================

-- 042: Deals carry the brand they are sold under (option-4 follow-through).
--
-- brand_organization_id on crm_deals — which brand this pursuit belongs to
--   (Teach HQ vs Turner Price vs BespokeLMS). NULL = general / unattributed.
--   Same rule as crm_account_brands: a brand must be a platform or operator
--   organisation; guarded by trigger since a CHECK cannot subquery.
--   ON DELETE SET NULL: losing a brand org never destroys deal history.

alter table public.crm_deals
  add column brand_organization_id uuid references public.organizations (id) on delete set null;

create index crm_deals_brand on public.crm_deals (owning_organization_id, brand_organization_id)
  where brand_organization_id is not null;

create or replace function public.crm_deal_brand_guard()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_type public.org_type;
begin
  if new.brand_organization_id is null then
    return new;
  end if;

  select o.type into v_type from public.organizations o where o.id = new.brand_organization_id;

  if v_type is null or v_type not in ('platform', 'operator') then
    raise exception 'crm_deals: brand must be a platform or operator organisation'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

create trigger crm_deals_brand_guard
  before insert or update of brand_organization_id on public.crm_deals
  for each row execute function public.crm_deal_brand_guard();

-- =============================================================================
-- 043: Follow-up task scheduling on the activity timeline.
--
-- assigned_to_profile_id — who is responsible for a task (transfer = change
--   it; NULL = unassigned/whoever logged it).
-- related_activity_id — the activity a follow-up was created from, so the
--   timeline can show "follow-up to: Sent proposal". Org-exact composite FK
--   (backed by a unique on (id, owning_organization_id)) with a column-list
--   SET NULL so history survives deletion of the trigger activity.
-- crm_activity_collaborators — colleagues jointly working a task (@-style),
--   alongside (not instead of) the responsible assignee.
-- =============================================================================

create unique index crm_activities_id_org on public.crm_activities (id, owning_organization_id);

alter table public.crm_activities
  add column assigned_to_profile_id uuid references public.profiles (id) on delete set null,
  add column related_activity_id uuid;

alter table public.crm_activities
  add constraint crm_activities_related_fk
  foreign key (related_activity_id, owning_organization_id)
  references public.crm_activities (id, owning_organization_id)
  on delete set null (related_activity_id);

create index crm_activities_open_tasks
  on public.crm_activities (owning_organization_id, assigned_to_profile_id, due_at)
  where activity_type = 'task' and completed_at is null;

create table public.crm_activity_collaborators (
  id uuid primary key default gen_random_uuid(),
  owning_organization_id uuid not null references public.organizations (id) on delete cascade,
  activity_id uuid not null,
  profile_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (activity_id, profile_id),
  foreign key (activity_id, owning_organization_id)
    references public.crm_activities (id, owning_organization_id)
    on delete cascade
);

alter table public.crm_activity_collaborators enable row level security;

create policy crm_activity_collaborators_org on public.crm_activity_collaborators
  for all using (public.crm_org_access(owning_organization_id))
  with check (public.crm_org_access(owning_organization_id));
