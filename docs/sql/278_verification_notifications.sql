-- 278: telling developers things.
--
-- The module could tell a REPORTER what happened to their report, in plain
-- English, through five well-written trigger branches. It could tell a
-- DEVELOPER nothing at all. There is no event for work being assigned, none for
-- being mentioned — work_item_mentions has never had a row written to it — and
-- until now nothing for a verification that failed. A developer whose item was
-- sent back at the gate found out by looking.
--
-- That was the other half of the original question: recording issues, and
-- feeding them back to the people who have to fix them. This is the second half.
--
-- Everything rides the existing engine: rows in notification_events for the
-- catalogue, preferences and channels, and triggers writing notifications rows
-- the same way bug_report_reporter_feedback already does. No second system.
--
-- Two events are registered is_active = false — automated_suite_failed and
-- triage_overdue. Their stories are not built. They are declared now so the
-- catalogue is honest about what exists rather than growing a gap somebody
-- later fills with a second mechanism.
--
-- Every trigger stays quiet about your own actions. A notification telling you
-- what you just did is noise, and noise is how people learn to ignore the bell.
--
-- Applied to Supabase project pqmdtqsscyltykgcwwus via the Supabase MCP
-- connector as migration 278_verification_notifications.

insert into notification_events
    (key, name, description, domain, category, suppression_class, tier,
     recipient_roles, channels, content_tier, is_scheduled, is_active)
values
    ('work_item_assigned', 'Work assigned to you',
     'Sent to the person a work item is assigned to, at the moment it becomes theirs. Its absence is why developers have been finding out by looking.',
     'workflow', 'transactional', 'preference', 'p1', '{}', '{email,notification}', 't1_operational', false, true),

    ('work_item_mentioned', 'You were mentioned',
     'Sent when somebody names you in a comment on a work item. work_item_mentions has existed since the board shipped and has never been written to.',
     'workflow', 'transactional', 'preference', 'p1', '{}', '{email,notification}', 't1_operational', false, true),

    ('verification_failed', 'Your item was sent back',
     'Sent to the assignee when an item is rejected at a stage gate, carrying the verifier''s reason verbatim. The single most useful message in the module: it is the one that tells somebody there is work to redo.',
     'workflow', 'transactional', 'preference', 'p1', '{}', '{email,notification}', 't1_operational', false, true),

    ('verification_requested', 'Something is waiting on you to verify',
     'Sent to product-capability holders other than the assignee when an item enters a gated stage. Not the assignee: they cannot verify their own work.',
     'workflow', 'transactional', 'preference', 'p2', '{}', '{notification}', 't1_operational', false, true),

    ('test_run_assigned', 'A test run is yours',
     'Sent to the person a run is assigned to when it is created or handed over.',
     'workflow', 'transactional', 'preference', 'p2', '{}', '{email,notification}', 't1_operational', false, true),

    ('release_gate_blocked', 'A release cannot go out yet',
     'Sent to product-capability holders when a release is signed off as rejected, or when a required suite has not passed.',
     'workflow', 'transactional', 'preference', 'p1', '{}', '{email,notification}', 't1_operational', false, true),

    ('automated_suite_failed', 'An automated suite failed on main',
     'Sent to product-capability holders when an ingested CI result reports failures on the main branch. Inert until CI ingestion is built; registered now so the catalogue is honest about what exists.',
     'workflow', 'transactional', 'preference', 'p1', '{}', '{email,notification}', 't1_operational', false, false),

    ('triage_overdue', 'Reports are waiting to be triaged',
     'A scheduled sweep telling product-capability holders which reports have passed their triage-due time. Inert until the triage ageing story is built.',
     'workflow', 'transactional', 'preference', 'p2', '{}', '{notification}', 't1_operational', true, false)
on conflict (key) do nothing;

-- ---- Assignment ------------------------------------------------------------

create or replace function work_item_assignment_notify()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare
    v_actor uuid;
    v_who   text;
begin
    if new.assignee_id is not distinct from old.assignee_id or new.assignee_id is null then
        return new;
    end if;

    v_actor := my_profile_id();

    -- Assigning something to yourself is not news.
    if v_actor is not distinct from new.assignee_id then
        return new;
    end if;

    v_who := coalesce(
        nullif(btrim((select p.full_name from profiles p where p.id = v_actor)), ''),
        'Somebody'
    );

    insert into notifications (user_id, type, title, body, link)
    values (new.assignee_id, 'work',
            'Work assigned to you',
            v_who || ' has given you: ' || new.title,
            '/platform/product/items/' || new.id::text);

    return new;
end;
$function$;

drop trigger if exists trg_work_item_assignment_notify on work_items;
create trigger trg_work_item_assignment_notify
    after update of assignee_id on work_items
    for each row execute function work_item_assignment_notify();

-- ---- Mentions --------------------------------------------------------------

create or replace function work_item_mention_notify()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare
    v_item  work_items%rowtype;
    v_who   text;
    v_actor uuid;
begin
    select * into v_item from work_items where id = new.work_item_id;
    if v_item.id is null then
        return new;
    end if;

    select author_id into v_actor from work_item_comments where id = new.comment_id;

    if v_actor is not distinct from new.profile_id then
        return new;
    end if;

    v_who := coalesce(
        nullif(btrim((select p.full_name from profiles p where p.id = v_actor)), ''),
        'Somebody'
    );

    insert into notifications (user_id, type, title, body, link)
    values (new.profile_id, 'work',
            'You were mentioned',
            v_who || ' named you on: ' || v_item.title,
            '/platform/product/items/' || v_item.id::text);

    return new;
end;
$function$;

drop trigger if exists trg_work_item_mention_notify on work_item_mentions;
create trigger trg_work_item_mention_notify
    after insert on work_item_mentions
    for each row execute function work_item_mention_notify();

-- ---- Verification verdicts -------------------------------------------------

create or replace function gate_signoff_notify()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare
    v_item  work_items%rowtype;
    v_who   text;
    v_title text;
    v_body  text;
begin
    if new.work_item_id is null then
        -- A release verdict. Tell the people who own the product, not one person.
        if new.verdict = 'rejected' then
            insert into notifications (user_id, type, title, body, link)
            select pc.profile_id, 'release',
                   'A release cannot go out yet',
                   'A release was held back. ' || coalesce(new.reason, ''),
                   '/platform/product/releases'
              from profile_capabilities pc
             where pc.capability = 'product'
               and pc.profile_id is distinct from new.verified_by;
        end if;
        return new;
    end if;

    select * into v_item from work_items where id = new.work_item_id;
    if v_item.id is null or v_item.assignee_id is null then
        return new;
    end if;

    -- Telling somebody they approved their own item is noise.
    if v_item.assignee_id is not distinct from new.verified_by then
        return new;
    end if;

    v_who := coalesce(
        nullif(btrim((select p.full_name from profiles p where p.id = new.verified_by)), ''),
        'Somebody'
    );

    if new.verdict = 'rejected' then
        v_title := 'Your item was sent back';
        v_body := v_item.title || ' -- ' || v_who || ' looked at this and it is not right yet.'
                  || coalesce(E'\n\n' || nullif(btrim(new.reason), ''), '');
    elsif new.verdict = 'approved' then
        v_title := 'Your item was verified';
        v_body := v_item.title || ' -- ' || v_who || ' checked it and agreed it does what it said.';
    else
        v_title := 'Your item went through on a waiver';
        v_body := v_item.title || ' -- ' || v_who || ' let this through without everything being met.'
                  || coalesce(E'\n\n' || nullif(btrim(new.reason), ''), '');
    end if;

    insert into notifications (user_id, type, title, body, link)
    values (v_item.assignee_id, 'work', v_title, v_body,
            '/platform/product/items/' || v_item.id::text);

    return new;
end;
$function$;

drop trigger if exists trg_gate_signoff_notify on gate_signoffs;
create trigger trg_gate_signoff_notify
    after insert on gate_signoffs
    for each row execute function gate_signoff_notify();

-- ---- Something is waiting to be verified -----------------------------------

create or replace function work_item_verification_requested()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare v_gate stage_gates%rowtype;
begin
    if new.stage_id is not distinct from old.stage_id then
        return new;
    end if;

    select * into v_gate from stage_gates where stage_id = new.stage_id and is_active;
    if v_gate.id is null then
        return new;
    end if;

    -- Everybody who could verify it, except the person who did the work. They
    -- are not allowed to verify it, so telling them it needs verifying is at
    -- best noise and at worst an invitation.
    insert into notifications (user_id, type, title, body, link)
    select pc.profile_id, 'work',
           'Something is waiting on you to verify',
           new.title || ' -- it has reached '
             || (select label from board_stages where id = new.stage_id) || '.',
           '/platform/product/items/' || new.id::text
      from profile_capabilities pc
     where pc.capability = 'product'
       and pc.profile_id is distinct from new.assignee_id;

    return new;
end;
$function$;

drop trigger if exists trg_work_item_verification_requested on work_items;
create trigger trg_work_item_verification_requested
    after update of stage_id on work_items
    for each row execute function work_item_verification_requested();

-- ---- A run handed to somebody ----------------------------------------------

create or replace function test_run_assignment_notify()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare v_title text;
begin
    if new.assigned_to is null then
        return new;
    end if;

    if tg_op = 'UPDATE' and new.assigned_to is not distinct from old.assigned_to then
        return new;
    end if;

    if new.assigned_to is not distinct from coalesce(new.started_by, my_profile_id()) then
        return new;
    end if;

    select p.title into v_title from test_plans p where p.id = new.plan_id;

    insert into notifications (user_id, type, title, body, link)
    values (new.assigned_to, 'work',
            'A test run is yours',
            coalesce(v_title, 'A verification run') || ' -- somebody has asked you to work through it.',
            '/platform/product/quality/runs/' || new.id::text);

    return new;
end;
$function$;

drop trigger if exists trg_test_run_assignment_notify on test_runs;
create trigger trg_test_run_assignment_notify
    after insert or update of assigned_to on test_runs
    for each row execute function test_run_assignment_notify();

-- ---- Close the surface these functions would otherwise expose --------------
--
-- Postgres grants EXECUTE on a new function to public, so PostgREST would list
-- all five at /rest/v1/rpc/. A trigger function is invoked by its trigger.

revoke execute on function work_item_assignment_notify()        from public, anon, authenticated;
revoke execute on function work_item_mention_notify()           from public, anon, authenticated;
revoke execute on function gate_signoff_notify()                from public, anon, authenticated;
revoke execute on function work_item_verification_requested()   from public, anon, authenticated;
revoke execute on function test_run_assignment_notify()         from public, anon, authenticated;

-- ---- Verification ----------------------------------------------------------

do $$
declare v_events integer; v_triggers integer; v_grants integer;
begin
    select count(*) into v_events from notification_events
     where key in ('work_item_assigned','work_item_mentioned','verification_failed',
                   'verification_requested','test_run_assigned','release_gate_blocked',
                   'automated_suite_failed','triage_overdue');
    if v_events <> 8 then raise exception 'Expected 8 events, found %', v_events; end if;

    select count(*) into v_triggers from pg_trigger
     where not tgisinternal and tgname in ('trg_work_item_assignment_notify',
        'trg_work_item_mention_notify','trg_gate_signoff_notify',
        'trg_work_item_verification_requested','trg_test_run_assignment_notify');
    if v_triggers <> 5 then raise exception 'Expected 5 triggers, found %', v_triggers; end if;

    select count(*) into v_grants from information_schema.routine_privileges
     where routine_schema = 'public'
       and routine_name in ('work_item_assignment_notify','work_item_mention_notify',
           'gate_signoff_notify','work_item_verification_requested','test_run_assignment_notify')
       and grantee in ('PUBLIC','anon','authenticated');
    if v_grants > 0 then raise exception '% execute grant(s) remain', v_grants; end if;

    raise notice 'Developers can now be told things: 8 events, 5 triggers, no RPC surface.';
end $$;
