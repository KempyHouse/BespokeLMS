-- =============================================================================
-- BespokeLMS — Supabase migration 047 (applied 2026-07-25)
-- CRM: account enrichment fields (Delightful Food Group data-entry feedback).
-- Reference copy of migration applied to project pqmdtqsscyltykgcwwus:
--   bespokelms_crm_account_enrichment_047
-- =============================================================================

-- social_links jsonb — {linkedin, facebook, instagram, x, youtube} URLs;
--   keys controlled app-side (CrmOptions::SOCIAL_KEYS).
-- company_number — Companies House number: KYC + dedupe anchor.
-- email — account-level primary email (info@/sales@).
-- account_role — role within a group (holding/operating/independent),
--   complementing parent/subsidiary links; list app-side.
-- founded_year / trading_as — context fields.
-- revenue_band — turnover band for qualification; list app-side.
-- (Multi-site addresses deliberately deferred: needs a child table.)

alter table public.crm_accounts
  add column social_links jsonb not null default '{}'::jsonb,
  add column company_number text,
  add column email text,
  add column account_role text,
  add column founded_year smallint,
  add column trading_as text,
  add column revenue_band text;
