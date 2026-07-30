-- 288: 287's revokes did nothing, and here is why.
--
-- Postgres grants EXECUTE on a new function to PUBLIC by default. Revoking
-- from anon and authenticated individually leaves the PUBLIC grant untouched,
-- so both roles still reach the function through it. The advisor kept
-- reporting the same three functions after 287 for exactly that reason.
--
-- Revoke from PUBLIC, then grant back only what is genuinely needed.
--
-- sales_org_access MUST stay executable by authenticated: row-level security
-- policies call it as the querying role, so revoking it there fails every
-- policy on the commercial layer shut. The other four are only ever invoked as
-- triggers, which do not require the calling role to hold execute at all.
--
-- NOTE FOR THE PLATFORM: 81 pre-existing functions carry the same PUBLIC
-- default. Deliberately not swept here -- that is its own piece of work and
-- should be a decision, not something done quietly alongside a feature.
--
-- Applied to Supabase project pqmdtqsscyltykgcwwus via the Supabase MCP
-- on 2026-07-29 (migration 20260729170716).

revoke execute on function public.sales_org_access(uuid) from public;
revoke execute on function public.esign_line_item_tenant_guard() from public;
revoke execute on function public.contract_clause_version_sync() from public;
revoke execute on function public.sales_touch_updated_at() from public;
revoke execute on function public.contract_notice_deadline_sync() from public;

grant execute on function public.sales_org_access(uuid) to authenticated;
