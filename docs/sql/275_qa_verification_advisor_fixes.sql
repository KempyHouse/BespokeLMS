-- 275: QA & Verification — close the advisories 274 opened.
--
-- The schema proposal said the new tables must not add to the advisor's list.
-- Applying 274 added six entries, all of them mine, all of them fixable without
-- changing behaviour:
--
-- * The two readiness views were created SECURITY DEFINER by default, which
--   means they read their underlying tables as their owner and quietly bypass
--   the RLS those tables carry. security_invoker = on hands the caller's own
--   permissions back to the query, so a view over work_items obeys the same
--   board policies a direct select would.
--
-- * The four trigger functions are SECURITY DEFINER because they must write
--   rows the caller cannot (bumping a bounce count, completing a run). That is
--   correct. What was not correct is that Postgres grants EXECUTE on a new
--   function to public, so PostgREST exposed all four at /rest/v1/rpc/ where
--   anon could call them. A trigger function is invoked by the trigger, never
--   by a client; revoking EXECUTE costs nothing and removes the surface.
--
-- Pre-existing advisories elsewhere in the schema are deliberately untouched
-- here — they are somebody else's decision to review, not this migration's.
--
-- Applied to Supabase project pqmdtqsscyltykgcwwus via the Supabase MCP
-- connector as migration 275_qa_verification_advisor_fixes.

alter view v_work_item_verification_readiness set (security_invoker = on);
alter view v_release_readiness set (security_invoker = on);

revoke execute on function test_case_snapshot()    from public, anon, authenticated;
revoke execute on function test_run_outcome()      from public, anon, authenticated;
revoke execute on function work_item_gate_guard()  from public, anon, authenticated;
revoke execute on function gate_signoff_bounce()   from public, anon, authenticated;

do $$
declare v_definer integer; v_grants integer;
begin
    select count(*) into v_definer
      from pg_views v
      join pg_class c on c.relname = v.viewname
     where v.schemaname = 'public'
       and v.viewname in ('v_work_item_verification_readiness','v_release_readiness')
       and not coalesce((select option_value::boolean
                           from pg_options_to_table(c.reloptions)
                          where option_name = 'security_invoker'), false);
    if v_definer > 0 then
        raise exception '% readiness view(s) are still SECURITY DEFINER', v_definer;
    end if;

    select count(*) into v_grants
      from information_schema.routine_privileges
     where routine_schema = 'public'
       and routine_name in ('test_case_snapshot','test_run_outcome',
                            'work_item_gate_guard','gate_signoff_bounce')
       and grantee in ('PUBLIC','anon','authenticated');
    if v_grants > 0 then
        raise exception '% execute grant(s) remain on the QA trigger functions', v_grants;
    end if;

    raise notice 'QA advisories closed: views are security_invoker, trigger functions are not callable over RPC.';
end $$;
