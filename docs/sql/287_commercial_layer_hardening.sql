-- 287: the commercial layer's views were reading past row-level security.
--
-- FOUND BY THE SUPABASE SECURITY ADVISOR immediately after 281-285, which
-- reported all three new views as ERROR severity. Worth recording why, because
-- it is a trap anyone adding a view here will fall into.
--
-- A Postgres view runs with its OWNER's rights unless told otherwise. So a
-- view over a table with row-level security quietly returns every tenant's
-- rows to whoever queries it, however careful the policy on the table is. On a
-- multi-tenant platform that is a tenant-isolation hole, not a lint.
-- security_invoker = on makes each view honour the policies of the person
-- actually querying it.
--
-- Also here: two trigger functions were left with a mutable search_path, and
-- the anon role had execute on functions it has no business calling.
--
-- Applied to Supabase project pqmdtqsscyltykgcwwus via the Supabase MCP
-- on 2026-07-29 (migration 20260729170651). Re-running the advisor afterwards
-- returned zero errors.

alter view public.v_esign_document_totals set (security_invoker = on);
alter view public.v_email_engagement_human set (security_invoker = on);
alter view public.v_contract_clause_usage set (security_invoker = on);

create or replace function public.sales_touch_updated_at()
returns trigger
language plpgsql
set search_path to 'public'
as $$
begin
    new.updated_at := now();
    return new;
end;
$$;

create or replace function public.contract_notice_deadline_sync()
returns trigger
language plpgsql
set search_path to 'public'
as $$
begin
    if new.next_renewal_on is not null and new.renewal_notice_days is not null then
        new.notice_deadline_on := new.next_renewal_on - new.renewal_notice_days;
    end if;
    return new;
end;
$$;

revoke execute on function public.sales_org_access(uuid) from anon;
revoke execute on function public.esign_line_item_tenant_guard() from anon, authenticated;
revoke execute on function public.contract_clause_version_sync() from anon, authenticated;
revoke execute on function public.sales_touch_updated_at() from anon, authenticated;
revoke execute on function public.contract_notice_deadline_sync() from anon, authenticated;
