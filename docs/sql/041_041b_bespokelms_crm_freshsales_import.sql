-- =============================================================================
-- BespokeLMS — Supabase migrations 041 + 041b (applied 2026-07-25)
-- CRM Phase 4: Freshsales import (accounts, contacts, full history).
-- Reference copy of the migrations already applied to project pqmdtqsscyltykgcwwus:
--   20260725100129_bespokelms_crm_freshsales_import_041
--   20260725100205_bespokelms_crm_import_history_custom_041b
-- =============================================================================

-- 041: Phase 4 — Freshsales import (API pull into the BespokeLMS book).
--
-- crm_import_connections — one connection per owning organisation (the
--   Freshsales domain + API key). OWNER-ONLY RLS: the key is a secret, so
--   unlike other CRM tables it is NOT readable via crm_org_access; the app
--   reads it with the service-role key on owner-gated routes only.
-- external_ref on accounts/contacts — the Freshsales record id, making the
--   import idempotent: re-running updates instead of duplicating.
-- crm_import_runs — the audit trail every run leaves behind (dry runs too).

create table public.crm_import_connections (
  owning_organization_id uuid primary key references public.organizations (id) on delete cascade,
  provider text not null default 'freshsales',
  domain text not null,
  api_key text not null,
  last_tested_at timestamptz,
  last_run_at timestamptz,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint crm_import_connections_domain_shape check (domain ~* '^[a-z0-9][a-z0-9-]{0,62}$')
);

alter table public.crm_import_connections enable row level security;

create policy crm_import_connections_owner on public.crm_import_connections
  for all using (public.is_platform_owner())
  with check (public.is_platform_owner());

alter table public.crm_accounts add column external_ref text;
alter table public.crm_contacts add column external_ref text;

create unique index crm_accounts_external_ref
  on public.crm_accounts (owning_organization_id, external_ref)
  where external_ref is not null;

create unique index crm_contacts_external_ref
  on public.crm_contacts (owning_organization_id, external_ref)
  where external_ref is not null;

create table public.crm_import_runs (
  id uuid primary key default gen_random_uuid(),
  owning_organization_id uuid not null references public.organizations (id) on delete cascade,
  provider text not null default 'freshsales',
  mode text not null check (mode in ('dry_run', 'live')),
  status text not null default 'completed' check (status in ('completed', 'partial', 'failed')),
  stats jsonb not null default '{}'::jsonb,
  error text,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now()
);

create index crm_import_runs_recent
  on public.crm_import_runs (owning_organization_id, created_at desc);

alter table public.crm_import_runs enable row level security;

create policy crm_import_runs_org on public.crm_import_runs
  for all using (public.crm_org_access(owning_organization_id))
  with check (public.crm_org_access(owning_organization_id));

-- =============================================================================
-- 041b: History + custom-field capture for the Freshsales import.
--
-- custom (jsonb) on accounts/contacts — every Freshsales field that has no
--   first-class column yet (including their custom fields) is preserved
--   here verbatim, so nothing is lost and fields can be promoted to real
--   columns later without re-importing.
-- crm_activities.external_ref — Freshsales note/task/appointment ids, so
--   history imports are idempotent exactly like accounts and contacts.
-- =============================================================================

alter table public.crm_accounts add column custom jsonb not null default '{}'::jsonb;
alter table public.crm_contacts add column custom jsonb not null default '{}'::jsonb;

alter table public.crm_activities add column external_ref text;

create unique index crm_activities_external_ref
  on public.crm_activities (owning_organization_id, external_ref)
  where external_ref is not null;
