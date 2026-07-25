-- =============================================================================
-- BespokeLMS — Supabase migration 049 (applied 2026-07-25)
-- CRM: queued email campaigns (segment mass-send beyond the inline cap).
-- Reference copy of migration applied to project pqmdtqsscyltykgcwwus:
--   bespokelms_crm_campaigns_049
-- =============================================================================

-- A campaign snapshots its recipients at queue time (do-not-contact people
-- and blank/duplicate addresses excluded app-side), then a batched sender
-- drains the queue — scheduler-driven (crm:campaigns-send) or manually from
-- the campaign page. Consent is re-checked at send time: a contact flagged
-- do-not-contact after queuing is skipped, never emailed.

create table public.crm_campaigns (
  id uuid primary key default gen_random_uuid(),
  owning_organization_id uuid not null references public.organizations(id) on delete cascade,
  segment_id uuid references public.crm_segments(id) on delete set null,
  name text not null,
  subject text not null,
  body_html text not null,
  status text not null default 'sending' check (status in ('sending','paused','done','cancelled')),
  created_by uuid references public.profiles(id) on delete set null,
  total_recipients integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  finished_at timestamptz,
  unique (id, owning_organization_id)
);

create table public.crm_campaign_recipients (
  id uuid primary key default gen_random_uuid(),
  owning_organization_id uuid not null,
  campaign_id uuid not null,
  contact_id uuid references public.crm_contacts(id) on delete set null,
  email text not null,
  status text not null default 'queued' check (status in ('queued','sent','failed','skipped')),
  error text,
  sent_at timestamptz,
  foreign key (campaign_id, owning_organization_id)
    references public.crm_campaigns(id, owning_organization_id) on delete cascade,
  unique (campaign_id, email)
);

create index crm_campaign_recipients_queued_idx
  on public.crm_campaign_recipients (campaign_id)
  where status = 'queued';

create index crm_campaigns_sending_idx
  on public.crm_campaigns (owning_organization_id)
  where status = 'sending';

alter table public.crm_campaigns enable row level security;
alter table public.crm_campaign_recipients enable row level security;

create policy crm_campaigns_org on public.crm_campaigns
  for all using (crm_org_access(owning_organization_id))
  with check (crm_org_access(owning_organization_id));

create policy crm_campaign_recipients_org on public.crm_campaign_recipients
  for all using (crm_org_access(owning_organization_id))
  with check (crm_org_access(owning_organization_id));

-- Proven with rolled-back asserts on 2026-07-25:
--   1. duplicate email within a campaign refused (unique)       ✓
--   2. cross-org recipient refused (composite FK)               ✓
--   3. bogus status refused (check)                             ✓
--   4. deleting a campaign cascades to its recipients           ✓
