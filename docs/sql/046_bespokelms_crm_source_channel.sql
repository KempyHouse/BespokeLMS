-- =============================================================================
-- BespokeLMS — Supabase migration 046 (applied 2026-07-25)
-- CRM: structured provenance on accounts (data-entry feedback item 6).
-- Reference copy of migration applied to project pqmdtqsscyltykgcwwus:
--   bespokelms_crm_source_channel_046
-- =============================================================================

-- source_channel — HOW the record came to us, from a controlled list
--   (website / referral / event / outbound / import / existing), so
--   provenance is filterable; source_detail stays the free-text story.
--   List lives app-side (CrmOptions::SOURCE_CHANNELS), like industries.

alter table public.crm_accounts add column source_channel text;
