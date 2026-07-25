-- =============================================================================
-- BespokeLMS — Supabase migration 044 (applied 2026-07-25)
-- CRM Phase 4b: Freshsales deals import.
-- Reference copy of migration applied to project pqmdtqsscyltykgcwwus:
--   bespokelms_crm_deals_import_044
-- =============================================================================

-- 044: Phase 4b — Freshsales deals import.
--
-- external_ref on crm_deals — the Freshsales deal id (fs_d_…), making the
--   deals import idempotent exactly like accounts, contacts and history.
-- custom jsonb on crm_deals — unmapped Freshsales deal fields (custom
--   fields included, plus the original Freshsales stage name) preserved
--   verbatim for later promotion.

alter table public.crm_deals
  add column external_ref text,
  add column custom jsonb not null default '{}'::jsonb;

create unique index crm_deals_external_ref
  on public.crm_deals (owning_organization_id, external_ref)
  where external_ref is not null;
