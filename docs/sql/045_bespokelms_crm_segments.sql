-- =============================================================================
-- BespokeLMS — Supabase migration 045 (applied 2026-07-25)
-- CRM: Segments — saved contact filters for targeting (Audiences).
-- Reference copy of migration applied to project pqmdtqsscyltykgcwwus:
--   bespokelms_crm_segments_045
-- =============================================================================

-- A segment is a NAMED FILTER, not a static list: membership is evaluated
-- live against the book whenever it is viewed, so segments never go stale.
-- filters jsonb (v1 keys): lifecycle_stages[], industries[] (via linked
-- accounts), tenant ('any'|'yes'|'no' — works at a platform tenant),
-- include_dnc (bool; DNC contacts are excluded from sends by default).

create table public.crm_segments (
  id uuid primary key default gen_random_uuid(),
  owning_organization_id uuid not null references public.organizations (id) on delete cascade,
  name text not null,
  description text,
  filters jsonb not null default '{}'::jsonb,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index crm_segments_org on public.crm_segments (owning_organization_id, name);

alter table public.crm_segments enable row level security;

create policy crm_segments_org on public.crm_segments
  for all using (public.crm_org_access(owning_organization_id))
  with check (public.crm_org_access(owning_organization_id));
