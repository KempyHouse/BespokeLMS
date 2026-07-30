-- ============================================================================
-- 324 — Close what the security advisor found after 323, and one pre-existing
--       ERROR that predates it.
-- ============================================================================
--
-- A SHARPER VERSION OF MIGRATION 288'S LESSON. 288 concluded that revoking
-- EXECUTE from anon and authenticated does nothing, because Postgres grants it
-- to PUBLIC by default, so you must revoke from public. That was half the
-- picture. This project ALSO has default privileges that grant EXECUTE to
-- `authenticated` explicitly at creation time: every function created in 323
-- came out with proacl {postgres=X, authenticated=X, service_role=X}. So
-- revoking from public left the explicit grant untouched, and three internal
-- functions were reachable at /rest/v1/rpc/ by any signed-in user.
--
-- THE RULE, stated once so it stops being rediscovered: a function that is not
-- meant to be called from outside must be revoked from public AND from
-- authenticated AND from anon, by name — and then proacl must be read back,
-- because neither revoke on its own tells you the truth.
-- ============================================================================

-- Internal only. Two are trigger functions, which run with the trigger owner's
-- rights and never need a caller to hold EXECUTE; the third is a helper the
-- guard calls internally.
revoke execute on function workflow_subject_org(workflow_subject_type, uuid) from public, anon, authenticated;
revoke execute on function workflow_subject_tenant_guard() from public, anon, authenticated;
revoke execute on function workflow_log_is_append_only() from public, anon, authenticated;

-- workflow_subject_access KEEPS its grant to authenticated, and that is
-- deliberate: it appears in RLS policy expressions, which are evaluated with
-- the privileges of the querying role, so revoking it would make every policy
-- that uses it fail closed and hide workflow state from everybody. Same
-- reasoning as sales_org_access in migration 288. It returns only a boolean
-- about a subject the caller names, so the exposure is the ability to probe
-- whether a given id is accessible — which the corresponding SELECT already
-- reveals.
comment on function workflow_subject_access(workflow_subject_type, uuid) is
    'Whether the caller may see and move this subject through its workflow. Delegates to the access rule the subject already has. EXECUTE is granted to authenticated ON PURPOSE: this function is named in RLS policies, which evaluate with the querying role''s privileges, so revoking it would make those policies fail closed.';

-- search_path was not pinned. It raises unconditionally and touches no table, so
-- nothing could have been hijacked through it — but an unpinned search_path on a
-- security-adjacent function is a warning that trains people to ignore warnings.
create or replace function workflow_log_is_append_only()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $fn$
begin
    raise exception 'workflow_transition_log is append-only: a % is refused. An approval that happened cannot be made not to have happened.', lower(tg_op);
end $fn$;

revoke execute on function workflow_log_is_append_only() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Pre-existing ERROR, not introduced by 323, fixed while here
-- ---------------------------------------------------------------------------
--
-- v_nav_menu_drift was created without security_invoker, so it ran with its
-- owner's rights and read straight past RLS. This is the identical defect
-- migration 287 fixed on three other views; the nav drift view was added later
-- and did not inherit the lesson. A view is SECURITY DEFINER unless you say
-- otherwise, which is the wrong default and the reason this keeps recurring.
alter view v_nav_menu_drift set (security_invoker = on);
