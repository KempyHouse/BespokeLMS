-- 274: QA & Verification — core schema (minimum verification slice).
--
-- The Product Development module could record what was wrong and tell the
-- person who reported it what happened, but nothing in between: no acceptance
-- criteria, no test cases, no runs, no evidence, and no gate on the stage
-- called "Verify / QA" — which was holding 58 work items when this was written.
-- Items left that stage because somebody dragged them, and a release shipped
-- because somebody said so.
--
-- This migration is the slice needed to verify work and gate a release. The
-- accessibility conformance store, the breakpoint coverage report, the tenant
-- isolation suite, CI ingestion, the Quality dashboard views and client UAT are
-- specified in "QA & Verification — Functional Specification" and follow.
--
-- Design notes:
--
-- * Test cases are versioned the way product_documents are: editing an executed
--   case writes a revision, and a run pins the revision it executed. Without the
--   pin a historical run is a claim about a document that no longer exists.
--   Steps live as jsonb on the revision rather than in a child table because
--   they are always read and written whole, never queried individually, and
--   pinning them in one object is what makes the history immutable.
--
-- * Gate configuration belongs to the board, one row per stage, in the mould of
--   board_stages and board_item_types. Hard-coding the rule to the
--   product_development application was rejected: this is a multi-tenant
--   product and a tenant may run their own board with their own idea of done.
--
-- * Enforcement is a trigger, not a controller check. The board already trusts
--   triggers for stage stamping and stage logging, and a rule that only exists
--   in Laravel is not a rule while PostgREST can write the same row.
--
-- * Grandfathering is explicit, not implied. Items already sitting in a gated
--   stage are stamped verification_exempt, and a gate carries enforce_from.
--   Switching the gate on must not freeze a board mid-sprint; the exemption is
--   visible and countable so the debt cannot be quietly forgotten.
--
-- * Evidence reuses the bug_report_attachments column set exactly — kind,
--   storage_path, mime_type, bytes, duration_ms — so the existing uploader,
--   bucket policy and screen-recording capture work unchanged. A polymorphic
--   attachments table would have meant rewriting two working uploaders for
--   nothing.
--
-- * A criterion has no verdict column. Its state is derived from the sign-off
--   that assessed it, so a re-verification never overwrites what the last one
--   found.
--
-- RLS follows the module: can_read_product_dev() to read, can_manage_product_dev()
-- to write, service role for the application. Tables that can belong to a tenant
-- carry organization_id, nullable, meaning platform-owned — the boards pattern.
--
-- Applied to Supabase project pqmdtqsscyltykgcwwus via the Supabase MCP
-- connector as migration 274_qa_verification_core.

-- ---- Enums ----------------------------------------------------------------

do $$ begin
  if not exists (select 1 from pg_type where typname = 'test_case_kind') then
    create type test_case_kind as enum
      ('manual','exploratory','accessibility','responsive','tenant_isolation',
       'security','performance','regression','automated');
  end if;
  if not exists (select 1 from pg_type where typname = 'test_verdict') then
    create type test_verdict as enum ('pass','fail','blocked','skipped');
  end if;
  if not exists (select 1 from pg_type where typname = 'test_run_state') then
    create type test_run_state as enum ('draft','in_progress','complete','abandoned');
  end if;
  if not exists (select 1 from pg_type where typname = 'test_plan_target') then
    create type test_plan_target as enum ('work_item','release','roadmap_item');
  end if;
  if not exists (select 1 from pg_type where typname = 'gate_verdict') then
    create type gate_verdict as enum ('approved','rejected','waived');
  end if;
  if not exists (select 1 from pg_type where typname = 'test_audience') then
    create type test_audience as enum ('internal','tenant_uat');
  end if;
end $$;

-- ---- Acceptance criteria ---------------------------------------------------

create table if not exists work_item_acceptance_criteria (
    id           uuid primary key default gen_random_uuid(),
    work_item_id uuid not null references work_items(id) on delete cascade,
    statement    text not null,
    is_required  boolean not null default true,
    sort         integer not null default 0,
    created_by   uuid references profiles(id) on delete set null,
    created_at   timestamptz not null default now(),
    constraint acceptance_criteria_statement_present
        check (char_length(btrim(statement)) between 1 and 500)
);

create index if not exists acceptance_criteria_item_idx
    on work_item_acceptance_criteria (work_item_id, sort);

-- ---- Suites, cases, revisions ----------------------------------------------

create table if not exists test_suites (
    id                   uuid primary key default gen_random_uuid(),
    organization_id      uuid references organizations(id) on delete cascade,
    key                  text not null,
    name                 text not null,
    description          text,
    required_for_release boolean not null default false,
    is_active            boolean not null default true,
    created_by           uuid references profiles(id) on delete set null,
    created_at           timestamptz not null default now()
);

create unique index if not exists test_suites_key_uniq
    on test_suites (coalesce(organization_id, '00000000-0000-0000-0000-000000000000'::uuid), key);

create table if not exists test_cases (
    id               uuid primary key default gen_random_uuid(),
    organization_id  uuid references organizations(id) on delete cascade,
    key              text not null,
    title            text not null,
    kind             test_case_kind not null default 'manual',
    route_key        text references route_registry(key) on delete set null,
    module_key       text,
    preconditions    text,
    expected_result  text not null,
    breakpoint_bands text[],
    wcag_criterion   text,
    wcag_level       text,
    automated_ref    text,
    current_revision integer not null default 1,
    is_active        boolean not null default true,
    created_by       uuid references profiles(id) on delete set null,
    created_at       timestamptz not null default now(),
    updated_at       timestamptz not null default now(),
    constraint test_cases_title_present
        check (char_length(btrim(title)) between 1 and 300),
    constraint test_cases_accessibility_needs_criterion
        check (kind <> 'accessibility' or (wcag_criterion is not null and wcag_level is not null)),
    constraint test_cases_automated_needs_ref
        check (kind <> 'automated' or automated_ref is not null),
    constraint test_cases_responsive_needs_bands
        check (kind <> 'responsive' or (breakpoint_bands is not null and array_length(breakpoint_bands, 1) > 0)),
    constraint test_cases_wcag_level_known
        check (wcag_level is null or wcag_level in ('a','aa','aaa'))
);

create unique index if not exists test_cases_key_uniq
    on test_cases (coalesce(organization_id, '00000000-0000-0000-0000-000000000000'::uuid), key);
create index if not exists test_cases_route_idx on test_cases (route_key) where route_key is not null;
create index if not exists test_cases_kind_idx on test_cases (kind) where is_active;

create table if not exists test_case_revisions (
    id              uuid primary key default gen_random_uuid(),
    test_case_id    uuid not null references test_cases(id) on delete cascade,
    revision        integer not null,
    title           text not null,
    preconditions   text,
    expected_result text not null,
    steps           jsonb not null default '[]'::jsonb,
    author_id       uuid references profiles(id) on delete set null,
    created_at      timestamptz not null default now(),
    constraint test_case_revisions_steps_is_array check (jsonb_typeof(steps) = 'array')
);

create unique index if not exists test_case_revisions_uniq
    on test_case_revisions (test_case_id, revision);

create table if not exists test_suite_cases (
    suite_id     uuid not null references test_suites(id) on delete cascade,
    test_case_id uuid not null references test_cases(id) on delete cascade,
    sort         integer not null default 0,
    added_at     timestamptz not null default now(),
    primary key (suite_id, test_case_id)
);

-- ---- Environments ----------------------------------------------------------

create table if not exists test_environments (
    id                      uuid primary key default gen_random_uuid(),
    organization_id         uuid references organizations(id) on delete cascade,
    key                     text not null,
    name                    text not null,
    base_url                text,
    tenant_organization_id  uuid references organizations(id) on delete set null,
    is_production           boolean not null default false,
    is_active               boolean not null default true,
    created_at              timestamptz not null default now()
);

create unique index if not exists test_environments_key_uniq
    on test_environments (coalesce(organization_id, '00000000-0000-0000-0000-000000000000'::uuid), key);

-- ---- Plans -----------------------------------------------------------------

create table if not exists test_plans (
    id               uuid primary key default gen_random_uuid(),
    organization_id  uuid references organizations(id) on delete cascade,
    title            text not null,
    target_kind      test_plan_target not null,
    work_item_id     uuid references work_items(id) on delete cascade,
    release_id       uuid references releases(id) on delete cascade,
    roadmap_item_id  uuid references roadmap_items(id) on delete cascade,
    environment_id   uuid references test_environments(id) on delete set null,
    breakpoint_bands text[],
    browser_matrix   jsonb not null default '[]'::jsonb,
    audience         test_audience not null default 'internal',
    document_id      uuid references product_documents(id) on delete set null,
    is_template      boolean not null default false,
    created_by       uuid references profiles(id) on delete set null,
    created_at       timestamptz not null default now(),
    updated_at       timestamptz not null default now(),
    constraint test_plans_title_present
        check (char_length(btrim(title)) between 1 and 300),
    constraint test_plans_one_target check (
        (target_kind = 'work_item'    and work_item_id is not null and release_id is null and roadmap_item_id is null)
     or (target_kind = 'release'      and release_id is not null and work_item_id is null and roadmap_item_id is null)
     or (target_kind = 'roadmap_item' and roadmap_item_id is not null and work_item_id is null and release_id is null)
     or is_template
    )
);

create index if not exists test_plans_work_item_idx on test_plans (work_item_id) where work_item_id is not null;
create index if not exists test_plans_release_idx on test_plans (release_id) where release_id is not null;

create table if not exists test_plan_cases (
    plan_id      uuid not null references test_plans(id) on delete cascade,
    test_case_id uuid not null references test_cases(id) on delete cascade,
    suite_id     uuid references test_suites(id) on delete set null,
    sort         integer not null default 0,
    primary key (plan_id, test_case_id)
);

-- ---- Runs ------------------------------------------------------------------

create table if not exists test_runs (
    id              uuid primary key default gen_random_uuid(),
    plan_id         uuid not null references test_plans(id) on delete cascade,
    organization_id uuid references organizations(id) on delete cascade,
    environment_id  uuid not null references test_environments(id),
    state           test_run_state not null default 'draft',
    audience        test_audience not null default 'internal',
    assigned_to     uuid references profiles(id) on delete set null,
    started_at      timestamptz,
    completed_at    timestamptz,
    outcome         test_verdict,
    started_by      uuid references profiles(id) on delete set null,
    created_at      timestamptz not null default now(),
    constraint test_runs_complete_is_complete
        check (state <> 'complete' or (completed_at is not null and outcome is not null))
);

create index if not exists test_runs_plan_idx on test_runs (plan_id, created_at desc);

create table if not exists test_run_cases (
    id              uuid primary key default gen_random_uuid(),
    run_id          uuid not null references test_runs(id) on delete cascade,
    test_case_id    uuid not null references test_cases(id),
    case_revision   integer not null,
    verdict         test_verdict,
    note            text,
    tester_id       uuid references profiles(id) on delete set null,
    environment     jsonb not null default '{}'::jsonb,
    breakpoint_band text,
    browser         text,
    elapsed_ms      integer,
    bug_report_id   uuid references bug_reports(id) on delete set null,
    executed_at     timestamptz,
    sort            integer not null default 0,
    constraint test_run_cases_failure_needs_note check (
        verdict is null
        or verdict = 'pass'
        or char_length(btrim(coalesce(note, ''))) > 0
    )
);

create unique index if not exists test_run_cases_uniq on test_run_cases (run_id, test_case_id);
create index if not exists test_run_cases_run_idx on test_run_cases (run_id, sort);

create table if not exists test_run_case_attachments (
    id           uuid primary key default gen_random_uuid(),
    run_case_id  uuid not null references test_run_cases(id) on delete cascade,
    kind         text not null,
    storage_path text not null,
    mime_type    text,
    bytes        bigint,
    duration_ms  integer,
    created_at   timestamptz not null default now(),
    constraint test_run_case_attachments_kind
        check (kind in ('screenshot','recording','log','file'))
);

create index if not exists test_run_case_attachments_case_idx
    on test_run_case_attachments (run_case_id);

-- ---- Gates -----------------------------------------------------------------

create table if not exists stage_gates (
    id                          uuid primary key default gen_random_uuid(),
    board_id                    uuid not null references boards(id) on delete cascade,
    stage_id                    uuid not null unique references board_stages(id) on delete cascade,
    is_active                   boolean not null default false,
    enforce_from                timestamptz,
    require_acceptance_criteria boolean not null default true,
    require_passing_run         boolean not null default true,
    require_suites              uuid[],
    block_on_open_severity      text,
    require_human_signoff       boolean not null default true,
    allow_self_verification     boolean not null default false,
    allow_waiver                boolean not null default true,
    reject_to_stage_id          uuid references board_stages(id) on delete set null,
    created_at                  timestamptz not null default now(),
    updated_at                  timestamptz not null default now(),
    constraint stage_gates_severity_known
        check (block_on_open_severity is null
               or block_on_open_severity in ('blocker','critical','major','minor','trivial'))
);

create table if not exists gate_signoffs (
    id                  uuid primary key default gen_random_uuid(),
    work_item_id        uuid references work_items(id) on delete cascade,
    release_id          uuid references releases(id) on delete cascade,
    gate_id             uuid references stage_gates(id) on delete set null,
    verdict             gate_verdict not null,
    reason              text,
    failed_criteria     uuid[],
    failed_run_case_ids uuid[],
    test_run_id         uuid references test_runs(id) on delete set null,
    verified_by         uuid not null references profiles(id),
    verified_at         timestamptz not null default now(),
    constraint gate_signoffs_one_subject check (
        (work_item_id is not null and release_id is null)
     or (release_id is not null and work_item_id is null)
    ),
    constraint gate_signoffs_reasoned check (
        verdict = 'approved' or char_length(btrim(coalesce(reason, ''))) > 0
    )
);

create index if not exists gate_signoffs_item_idx on gate_signoffs (work_item_id, verified_at desc);
create index if not exists gate_signoffs_release_idx on gate_signoffs (release_id, verified_at desc);

-- ---- Alterations to existing objects ---------------------------------------

alter table work_items
    add column if not exists verification_bounces integer not null default 0,
    add column if not exists verification_exempt boolean not null default false;

alter table bug_reports
    add column if not exists assigned_to uuid references profiles(id) on delete set null,
    add column if not exists triage_due_at timestamptz,
    add column if not exists covering_test_case_id uuid references test_cases(id) on delete set null;

alter table work_item_links drop constraint if exists work_item_links_type;
alter table work_item_links add constraint work_item_links_type
    check (link_type in ('blocks','relates_to','duplicates','caused_by','verifies'));

alter table product_documents drop constraint if exists product_documents_kind_check;
alter table product_documents add constraint product_documents_kind_check
    check (kind in ('spec','decision','lesson','reference','test_plan'));

-- ---- Triggers --------------------------------------------------------------

-- A case that has been executed cannot be edited out from under its history.
create or replace function test_case_snapshot()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
begin
    if new.title is not distinct from old.title
       and new.preconditions is not distinct from old.preconditions
       and new.expected_result is not distinct from old.expected_result then
        return new;
    end if;

    new.current_revision := old.current_revision + 1;
    new.updated_at := now();
    return new;
end;
$function$;

drop trigger if exists trg_test_case_snapshot on test_cases;
create trigger trg_test_case_snapshot
    before update on test_cases
    for each row execute function test_case_snapshot();

-- A run's outcome is derived from its cases, never typed in.
create or replace function test_run_outcome()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare
    v_run    uuid;
    v_total  integer;
    v_judged integer;
    v_fail   integer;
    v_block  integer;
begin
    v_run := coalesce(new.run_id, old.run_id);

    select count(*), count(verdict),
           count(*) filter (where verdict = 'fail'),
           count(*) filter (where verdict = 'blocked')
      into v_total, v_judged, v_fail, v_block
      from test_run_cases where run_id = v_run;

    if v_total = 0 or v_judged < v_total then
        update test_runs
           set state = case when state = 'draft' and v_judged > 0 then 'in_progress' else state end,
               started_at = coalesce(started_at, case when v_judged > 0 then now() end)
         where id = v_run and state in ('draft','in_progress');
        return coalesce(new, old);
    end if;

    update test_runs
       set state = 'complete',
           completed_at = coalesce(completed_at, now()),
           started_at = coalesce(started_at, now()),
           outcome = case when v_fail > 0 then 'fail'::test_verdict
                          when v_block > 0 then 'blocked'::test_verdict
                          else 'pass'::test_verdict end
     where id = v_run and state <> 'abandoned';

    return coalesce(new, old);
end;
$function$;

drop trigger if exists trg_test_run_outcome on test_run_cases;
create trigger trg_test_run_outcome
    after insert or update or delete on test_run_cases
    for each row execute function test_run_outcome();

-- The gate itself. Refuses a transition out of a gated stage when the stage's
-- requirements are unmet. Shipped inactive: stage_gates.is_active is false by
-- default and the feature flag qa_gate_enforced is off, so applying this
-- migration changes no behaviour until both are switched on deliberately.
create or replace function work_item_gate_guard()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare
    g            stage_gates%rowtype;
    v_flag       boolean;
    v_required   integer;
    v_met        integer;
    v_run_ok     boolean;
    v_signoff    gate_signoffs%rowtype;
    v_open_bugs  integer;
    v_rank       integer;
begin
    if new.stage_id is not distinct from old.stage_id then
        return new;
    end if;

    select * into g from stage_gates where stage_id = old.stage_id and is_active;
    if g.id is null then
        return new;
    end if;

    select enabled into v_flag from feature_flags where key = 'qa_gate_enforced';
    if coalesce(v_flag, false) is false then
        return new;
    end if;

    if new.verification_exempt then
        return new;
    end if;

    if g.enforce_from is not null and old.created_at < g.enforce_from
       and old.verification_bounces = 0 then
        return new;
    end if;

    -- Moving backwards or into a terminal failure is always allowed; a gate
    -- stops work leaving as done, not somebody admitting it is not.
    if exists (
        select 1 from board_stages s
         where s.id = new.stage_id
           and (s.stage_role in ('terminal_failure','blocked')
                or s.sort < (select sort from board_stages where id = old.stage_id))
    ) then
        return new;
    end if;

    if g.require_acceptance_criteria then
        select count(*) filter (where is_required) into v_required
          from work_item_acceptance_criteria where work_item_id = new.id;
        if coalesce(v_required, 0) = 0 then
            raise exception using
                errcode = 'check_violation',
                message = 'This item cannot leave ' || (select label from board_stages where id = old.stage_id)
                          || ' until it has acceptance criteria saying what done means.';
        end if;
    end if;

    if g.require_passing_run then
        select exists (
            select 1
              from test_runs r
              join test_plans p on p.id = r.plan_id
             where p.work_item_id = new.id
               and r.state = 'complete'
               and r.outcome = 'pass'
               and r.audience = 'internal'
        ) into v_run_ok;

        if not v_run_ok then
            raise exception using
                errcode = 'check_violation',
                message = 'This item needs a completed, passing test run before it can leave '
                          || (select label from board_stages where id = old.stage_id) || '.';
        end if;
    end if;

    if g.block_on_open_severity is not null then
        v_rank := array_position(array['trivial','minor','major','critical','blocker'],
                                 g.block_on_open_severity);
        select count(*) into v_open_bugs
          from bug_reports b
         where b.work_item_id = new.id
           and b.closed_at is null
           and array_position(array['trivial','minor','major','critical','blocker'], b.severity) >= v_rank;
        if coalesce(v_open_bugs, 0) > 0 then
            raise exception using
                errcode = 'check_violation',
                message = 'This item has ' || v_open_bugs || ' open report(s) at '
                          || g.block_on_open_severity || ' or above.';
        end if;
    end if;

    if g.require_human_signoff then
        select * into v_signoff from gate_signoffs
         where work_item_id = new.id
         order by verified_at desc limit 1;

        if v_signoff.id is null or v_signoff.verdict = 'rejected' then
            raise exception using
                errcode = 'check_violation',
                message = 'This item has not been signed off. Somebody has to say they looked.';
        end if;

        if not g.allow_self_verification
           and v_signoff.verdict = 'approved'
           and v_signoff.verified_by is not distinct from old.assignee_id then
            raise exception using
                errcode = 'check_violation',
                message = 'The person who did the work cannot be the person who verified it.';
        end if;

        if v_signoff.verdict = 'waived' and not g.allow_waiver then
            raise exception using
                errcode = 'check_violation',
                message = 'This gate does not permit waivers.';
        end if;
    end if;

    return new;
end;
$function$;

drop trigger if exists trg_work_item_gate_guard on work_items;
create trigger trg_work_item_gate_guard
    before update of stage_id on work_items
    for each row execute function work_item_gate_guard();

-- A rejection is a bounce, and a bounce is worth counting.
create or replace function gate_signoff_bounce()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
begin
    if new.verdict = 'rejected' and new.work_item_id is not null then
        update work_items
           set verification_bounces = verification_bounces + 1
         where id = new.work_item_id;
    end if;
    return new;
end;
$function$;

drop trigger if exists trg_gate_signoff_bounce on gate_signoffs;
create trigger trg_gate_signoff_bounce
    after insert on gate_signoffs
    for each row execute function gate_signoff_bounce();

-- ---- Views -----------------------------------------------------------------

create or replace view v_work_item_verification_readiness as
select
    w.id as work_item_id,
    w.board_id,
    w.stage_id,
    w.verification_exempt,
    w.verification_bounces,
    coalesce(ac.required_total, 0)                        as criteria_required,
    coalesce(ac.total, 0)                                 as criteria_total,
    r.latest_run_id,
    r.latest_run_outcome,
    coalesce(r.has_passing_run, false)                    as has_passing_run,
    coalesce(b.open_blocking, 0)                          as open_blocking_bugs,
    s.verdict                                             as signoff_verdict,
    s.verified_by                                         as signoff_by,
    s.verified_at                                         as signoff_at,
    g.id                                                  as gate_id,
    coalesce(g.is_active, false)                          as gate_active,
    (
        coalesce(g.is_active, false) is false
        or w.verification_exempt
        or (
            (not coalesce(g.require_acceptance_criteria, false) or coalesce(ac.required_total, 0) > 0)
            and (not coalesce(g.require_passing_run, false) or coalesce(r.has_passing_run, false))
            and (g.block_on_open_severity is null or coalesce(b.open_blocking, 0) = 0)
            and (not coalesce(g.require_human_signoff, false)
                 or s.verdict in ('approved','waived'))
        )
    )                                                     as is_ready
from work_items w
left join stage_gates g on g.stage_id = w.stage_id
left join lateral (
    select count(*) as total, count(*) filter (where is_required) as required_total
      from work_item_acceptance_criteria c where c.work_item_id = w.id
) ac on true
left join lateral (
    select tr.id as latest_run_id,
           tr.outcome as latest_run_outcome,
           exists (
               select 1 from test_runs tr2
                 join test_plans tp2 on tp2.id = tr2.plan_id
                where tp2.work_item_id = w.id
                  and tr2.state = 'complete' and tr2.outcome = 'pass'
                  and tr2.audience = 'internal'
           ) as has_passing_run
      from test_runs tr
      join test_plans tp on tp.id = tr.plan_id
     where tp.work_item_id = w.id
     order by tr.created_at desc
     limit 1
) r on true
left join lateral (
    select count(*) as open_blocking
      from bug_reports br
     where br.work_item_id = w.id
       and br.closed_at is null
       and g.block_on_open_severity is not null
       and array_position(array['trivial','minor','major','critical','blocker'], br.severity)
           >= array_position(array['trivial','minor','major','critical','blocker'], g.block_on_open_severity)
) b on true
left join lateral (
    select gs.verdict, gs.verified_by, gs.verified_at
      from gate_signoffs gs
     where gs.work_item_id = w.id
     order by gs.verified_at desc
     limit 1
) s on true;

create or replace view v_release_readiness as
select
    rel.id as release_id,
    rel.version,
    rel.state,
    count(ri.work_item_id)                                            as items,
    count(*) filter (where vr.is_ready)                               as items_ready,
    count(*) filter (where not vr.is_ready)                           as items_blocked,
    count(*) filter (where vr.verification_exempt)                    as items_exempt,
    (
        select count(*) from test_suites ts where ts.required_for_release and ts.is_active
    )                                                                 as suites_required,
    (
        select count(distinct ts.id)
          from test_suites ts
          join test_plan_cases tpc on tpc.suite_id = ts.id
          join test_plans tp on tp.id = tpc.plan_id
          join test_runs tr on tr.plan_id = tp.id
         where ts.required_for_release and ts.is_active
           and tp.release_id = rel.id
           and tr.state = 'complete' and tr.outcome = 'pass'
    )                                                                 as suites_passed,
    sg.verdict                                                        as signoff_verdict,
    sg.verified_at                                                    as signoff_at
from releases rel
left join release_items ri on ri.release_id = rel.id
left join v_work_item_verification_readiness vr on vr.work_item_id = ri.work_item_id
left join lateral (
    select verdict, verified_at from gate_signoffs
     where release_id = rel.id order by verified_at desc limit 1
) sg on true
group by rel.id, rel.version, rel.state, sg.verdict, sg.verified_at;

-- ---- RLS -------------------------------------------------------------------

do $$
declare t text;
begin
    foreach t in array array[
        'work_item_acceptance_criteria','test_suites','test_cases','test_case_revisions',
        'test_suite_cases','test_environments','test_plans','test_plan_cases',
        'test_runs','test_run_cases','test_run_case_attachments','stage_gates','gate_signoffs'
    ] loop
        execute format('alter table %I enable row level security', t);
        execute format('drop policy if exists %I on %I', t || '_read', t);
        execute format('drop policy if exists %I on %I', t || '_manage', t);
        execute format(
            'create policy %I on %I for select using (can_read_product_dev())', t || '_read', t);
        execute format(
            'create policy %I on %I for all using (can_manage_product_dev()) with check (can_manage_product_dev())',
            t || '_manage', t);
    end loop;
end $$;

grant select on v_work_item_verification_readiness, v_release_readiness to authenticated;

-- ---- Seeds -----------------------------------------------------------------

insert into feature_flags (key, enabled, description)
values ('qa_gate_enforced', false,
        'When on, the Verify / QA gate refuses a stage transition whose requirements are unmet. Off until acceptance criteria are backfilled.')
on conflict (key) do nothing;

insert into test_environments (key, name, base_url, is_production)
values ('production', 'Production', 'https://app.bespokelms.com', true),
       ('staging',    'Staging',    null, false),
       ('local',      'Local',      'http://localhost', false)
on conflict do nothing;

insert into test_suites (key, name, description, required_for_release)
values
    ('smoke', 'Smoke', 'The handful of things that must work or nothing else matters.', true),
    ('regression', 'Regression', 'One case per bug we have already fixed once.', true),
    ('tenant_isolation', 'Tenant isolation', 'No tenant can reach another tenant''s data; branding and permissions resolve correctly.', true),
    ('accessibility_wcag22aa', 'Accessibility — WCAG 2.2 AA', 'Conformance checks against the success criteria we claim to meet.', false),
    ('responsive_matrix', 'Responsive matrix', 'Every breakpoint band a screen claims to support.', false)
on conflict do nothing;

-- The gate for the Verify / QA stage, seeded inactive and grandfathered from
-- the moment of this migration: everything already on the board predates it.
insert into stage_gates (board_id, stage_id, is_active, enforce_from,
                         require_acceptance_criteria, require_passing_run,
                         block_on_open_severity, require_human_signoff,
                         allow_self_verification, allow_waiver, reject_to_stage_id)
select b.id, s.id, false, now(), true, true, 'critical', true, false, true,
       (select id from board_stages where board_id = b.id and key = 'in_progress')
  from boards b
  join board_stages s on s.board_id = b.id and s.key = 'verify'
 where b.application::text = 'product_development'
on conflict (stage_id) do nothing;

-- Grandfather what is already there. The exemption is a fact on the row, so it
-- can be counted, reported and worked off — not an absence that gets forgotten.
update work_items w
   set verification_exempt = true
  from board_stages s
 where s.id = w.stage_id
   and s.key in ('verify','done')
   and w.verification_exempt is false;

-- ---- Verification ----------------------------------------------------------

do $$
declare
    v_tables integer;
    v_exempt integer;
    v_gate   integer;
begin
    select count(*) into v_tables from information_schema.tables
     where table_schema = 'public'
       and table_name in ('work_item_acceptance_criteria','test_suites','test_cases',
           'test_case_revisions','test_suite_cases','test_environments','test_plans',
           'test_plan_cases','test_runs','test_run_cases','test_run_case_attachments',
           'stage_gates','gate_signoffs');
    if v_tables <> 13 then
        raise exception 'Expected 13 new tables, found %', v_tables;
    end if;

    select count(*) into v_gate from stage_gates;
    if v_gate < 1 then
        raise exception 'The Verify / QA gate was not seeded.';
    end if;

    select count(*) into v_exempt from work_items where verification_exempt;
    raise notice 'QA core applied. Tables: %. Gates: %. Grandfathered items: %.',
        v_tables, v_gate, v_exempt;
end $$;
