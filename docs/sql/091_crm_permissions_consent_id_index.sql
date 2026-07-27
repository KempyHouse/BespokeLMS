-- 091: the join between the cookie-consent ledger and the CRM permission ledger.
--
-- A web form that captures marketing consent stores the browser's cookie
-- consent id in the permission's evidence. When the same browser later turns
-- the Marketing purpose off, the runtime looks up every consent-basis grant
-- carrying that id (ConsentWithdrawalSync). That lookup filters on
-- evidence->>'consent_id', which without an index is a sequential scan of an
-- append-only ledger that only ever grows.
--
-- Partial: most permission rows (imports, console edits, unsubscribes) carry
-- no consent id, and indexing their nulls would buy nothing.

create index if not exists crm_permissions_consent_id_idx
    on public.crm_permissions ((evidence->>'consent_id'))
    where evidence ? 'consent_id';
