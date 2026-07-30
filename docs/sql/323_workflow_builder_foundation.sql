-- ============================================================================
-- 323 — Workflow and approval builder: the foundation
-- ============================================================================
--
-- WHY THIS EXISTS. On 30 July 2026 the platform had two unrelated approval
-- mechanisms and neither worked properly.
--
--   · COURSES had workflow_states and workflow_transitions — a real state
--     machine with four-eyes and capability rules — and the publish path never
--     consulted it. CourseStatusLogic::actionPublish() asks
--     courseHasApprovalWorkflow(), which queries a table named
--     course_approval_workflows that does not exist; the request errors, the
--     surrounding catch (\Throwable) returns false, and publish takes its
--     "no workflow: publish directly" branch. 29 rows in course_workflow_state
--     and 19 published course versions say the workflow screen was moving work
--     through states the publish button ignored.
--
--   · PROPOSALS had a second implementation entirely — approver rows in
--     esign_recipients, the esign_document_status enum, and a $canSend
--     expression in a Blade template. It never touched workflow_states.
--
-- WHAT WAS ACTUALLY MISSING was not a state machine. It was the idea that a
-- workflow is A THING WITH A NAME. States and transitions were keyed by
-- organization_id alone, so an organisation had one flat set of states and a
-- proposal could not have different steps from a course. That is the whole of
-- the problem this migration fixes; everything else here follows from it.
--
-- WHY VERSIONED, on the navigation-menu-builder pattern rather than the board
-- pattern. An approval path must not change underneath work already in flight.
-- A proposal sitting in review under a three-step path must not silently
-- acquire a fourth step because somebody edited the workflow this afternoon,
-- and an approval already given must not be reopened by a wording change to
-- the state it was given in. So a subject pins the version it entered under,
-- exactly as a published pathway pins its enrolments, and versions are only
-- deleted when nothing stands in them (on delete restrict, deliberately).
--
-- WHAT THIS MIGRATION DOES NOT DO, on purpose:
--   · It seeds exactly ONE workflow — course_approval, from the rows already
--     there. It does NOT add the proposal workflow. CourseStatusLogic reads
--     workflow_states filtered by organization_id is null and NOT by workflow,
--     so a second workflow's states would appear on the course workflow screen
--     today. The proposal workflow can only be seeded after the application
--     filters by version. Ordering matters and this is the safe end of it.
--   · It changes no application behaviour. Every column the application reads
--     keeps its name, type and meaning.
--   · It does not create course_approval_workflows. Per-course opt-in is the
--     wrong model — it makes approval something a human must remember to add.
--
-- STD-DB-006: claimed in schema_change_log at the end of this file.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

-- Exactly two members, because an enum that guesses at future members is a
-- free-text column with extra steps. Adding a third is one line and a
-- deliberate decision about what a workflow is allowed to govern.
create type workflow_subject_type as enum ('course_version', 'esign_document');

create type workflow_version_state as enum ('draft', 'published', 'superseded');

-- MANUAL is what courses have today: a human ticks "Accessibility checked" and
-- their name and the time are recorded. Useful, and unverifiable.
-- AUTOMATIC names a registered evaluator that reads the subject and answers
-- yes or no with a sentence saying why. The distinction is the point: a
-- tick-box records an assertion, an automatic check records a fact, and a
-- proposal that went out with no pricing was never short of somebody willing
-- to tick a box.
create type workflow_check_kind as enum ('manual', 'automatic');

-- ---------------------------------------------------------------------------
-- The definition
-- ---------------------------------------------------------------------------

create table workflows (
    id uuid primary key default gen_random_uuid(),
    -- NULL means the platform default, inherited by every tenant that has not
    -- defined its own. Same convention as workflow_states.organization_id,
    -- nav menus and design tokens.
    owning_organization_id uuid references organizations (id) on delete cascade,
    key text not null,
    name text not null,
    subject_type workflow_subject_type not null,
    description text,
    is_active boolean not null default true,
    created_by uuid references profiles (id) on delete set null,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint workflows_key_format check (key ~ '^[a-z][a-z0-9_]*$')
);

-- NULLS NOT DISTINCT so the platform default is genuinely unique per key: with
-- the default null-handling, two rows with a null organisation and the same key
-- would both be allowed, which is how a platform default quietly becomes two
-- platform defaults.
create unique index workflows_org_key_uniq
    on workflows (owning_organization_id, key) nulls not distinct;

create index workflows_subject_type_idx on workflows (subject_type) where is_active;

comment on table workflows is
    'A named approval path with its own states. Courses and proposals can now differ; before this table an organisation had exactly one flat set of states.';
comment on column workflows.owning_organization_id is
    'NULL is the platform default, inherited by tenants that define no workflow of their own for this subject type.';
comment on column workflows.subject_type is
    'What this workflow governs. A workflow cannot be pointed at a subject of a different type — enforced by workflow_subject_tenant_guard().';

create table workflow_versions (
    id uuid primary key default gen_random_uuid(),
    workflow_id uuid not null references workflows (id) on delete cascade,
    version_no integer not null,
    state workflow_version_state not null default 'draft',
    notes text,
    created_by uuid references profiles (id) on delete set null,
    created_at timestamptz not null default now(),
    published_at timestamptz,
    published_by uuid references profiles (id) on delete set null,
    constraint workflow_versions_no_positive check (version_no >= 1),
    constraint workflow_versions_version_unique unique (workflow_id, version_no),
    -- A draft has never been published; anything else has. Superseded versions
    -- keep their published_at because "when was this the live path" is exactly
    -- the question an audit asks.
    constraint workflow_versions_publish_stamp
        check ((state = 'draft') = (published_at is null))
);

-- One live path per workflow, enforced by the database rather than by whoever
-- wrote the promote function.
create unique index workflow_versions_one_published
    on workflow_versions (workflow_id) where state = 'published';

create index workflow_versions_workflow_idx on workflow_versions (workflow_id, version_no desc);

comment on table workflow_versions is
    'Draft, published, superseded — the nav-menu-builder pattern. A subject in flight pins the version it entered under, so editing a workflow never changes the path under work already in progress.';

-- ---------------------------------------------------------------------------
-- The existing tables become versioned
-- ---------------------------------------------------------------------------
--
-- Added nullable, backfilled, then made NOT NULL, so the table is never in a
-- state the application cannot read. organization_id is left in place and
-- becomes redundant — the workflow carries the organisation now — and is
-- dropped in a later migration once nothing reads it.

alter table workflow_states
    add column version_id uuid references workflow_versions (id) on delete cascade;

alter table workflow_transitions
    add column version_id uuid references workflow_versions (id) on delete cascade;

alter table workflow_checklist_items
    add column version_id uuid references workflow_versions (id) on delete cascade,
    add column check_kind workflow_check_kind not null default 'manual',
    add column check_rule text,
    -- A checklist item blocks ONE transition, not the workflow as a whole.
    -- "Pricing is present" blocks draft -> in_review; it has nothing to say
    -- about publish -> retire.
    add column blocks_transition_id uuid references workflow_transitions (id) on delete cascade;

alter table workflow_checklist_items
    add constraint workflow_checklist_items_rule_when_automatic
        check ((check_kind = 'automatic') = (check_rule is not null));

comment on column workflow_checklist_items.check_rule is
    'Names a registered evaluator in the application, e.g. proposal_has_priced_line_items. NOT validated here: the registry is a PHP array and SQL cannot read it. That is the same blind spot the navigation route registry has, and it is closed by a test, not by a constraint.';
comment on column workflow_states.organization_id is
    'DEPRECATED by migration 323. The organisation now comes from workflows.owning_organization_id via version_id. Retained until the application stops reading it, then dropped.';
comment on column workflow_transitions.organization_id is
    'DEPRECATED by migration 323 — see workflow_states.organization_id.';
comment on column workflow_checklist_items.organization_id is
    'DEPRECATED by migration 323 — see workflow_states.organization_id.';

-- ---------------------------------------------------------------------------
-- Seed the course workflow from what is already there
-- ---------------------------------------------------------------------------

insert into workflows (key, name, subject_type, description)
values (
    'course_approval',
    'Course approval',
    'course_version',
    'Draft, review, approve, publish, review due, retire. Seeded from the six states and nine transitions that existed before the builder, unchanged.'
);

insert into workflow_versions (workflow_id, version_no, state, notes, published_at)
select w.id, 1, 'published',
       'Seeded by migration 323 from the pre-builder rows. Published on creation because this path was already the live one.',
       now()
from workflows w
where w.key = 'course_approval' and w.owning_organization_id is null;

update workflow_states s
set version_id = v.id
from workflow_versions v
join workflows w on w.id = v.workflow_id
where w.key = 'course_approval'
  and w.owning_organization_id is null
  and v.version_no = 1
  and s.organization_id is null
  and s.version_id is null;

update workflow_transitions t
set version_id = v.id
from workflow_versions v
join workflows w on w.id = v.workflow_id
where w.key = 'course_approval'
  and w.owning_organization_id is null
  and v.version_no = 1
  and t.organization_id is null
  and t.version_id is null;

update workflow_checklist_items i
set version_id = v.id
from workflow_versions v
join workflows w on w.id = v.workflow_id
where w.key = 'course_approval'
  and w.owning_organization_id is null
  and v.version_no = 1
  and i.organization_id is null
  and i.version_id is null;

-- Fail loudly rather than leave an unversioned row behind. If any tenant had
-- defined its own states this would catch them, and they need their own
-- workflow row rather than a silent NULL.
do $$
declare
    orphans integer;
begin
    select (select count(*) from workflow_states where version_id is null)
         + (select count(*) from workflow_transitions where version_id is null)
         + (select count(*) from workflow_checklist_items where version_id is null)
    into orphans;

    if orphans > 0 then
        raise exception
            'Migration 323 left % workflow definition row(s) with no version. Tenant-specific states need their own workflows row before this migration can complete.',
            orphans;
    end if;
end $$;

alter table workflow_states alter column version_id set not null;
alter table workflow_transitions alter column version_id set not null;
alter table workflow_checklist_items alter column version_id set not null;

-- Uniqueness within a version, which is what these always meant.
create unique index workflow_states_version_key_uniq
    on workflow_states (version_id, key);
create unique index workflow_transitions_version_action_uniq
    on workflow_transitions (version_id, from_state_id, action);
create index workflow_checklist_items_version_idx
    on workflow_checklist_items (version_id, sort);

-- ---------------------------------------------------------------------------
-- Where a subject currently stands
-- ---------------------------------------------------------------------------

create table workflow_subject_states (
    id uuid primary key default gen_random_uuid(),
    -- on delete restrict, not cascade: a version something is standing in is
    -- not deletable. Losing the definition of the path a document is halfway
    -- along would make its position unreadable.
    workflow_version_id uuid not null references workflow_versions (id) on delete restrict,
    subject_type workflow_subject_type not null,
    subject_id uuid not null,
    state_id uuid not null references workflow_states (id) on delete restrict,
    entered_at timestamptz not null default now(),
    entered_by uuid references profiles (id) on delete set null,
    updated_at timestamptz not null default now(),
    constraint workflow_subject_states_one_per_subject unique (subject_type, subject_id)
);

create index workflow_subject_states_version_idx on workflow_subject_states (workflow_version_id);
create index workflow_subject_states_state_idx on workflow_subject_states (state_id);

comment on table workflow_subject_states is
    'One row per subject: where it stands and which workflow version it entered under. Replaces course_workflow_state, whose subject could only ever be a course version.';

-- ---------------------------------------------------------------------------
-- What happened, append-only
-- ---------------------------------------------------------------------------

create table workflow_transition_log (
    id uuid primary key default gen_random_uuid(),
    workflow_version_id uuid not null references workflow_versions (id) on delete restrict,
    subject_type workflow_subject_type not null,
    subject_id uuid not null,
    -- Nullable: the first entry into a workflow comes from nowhere.
    from_state_id uuid references workflow_states (id) on delete set null,
    to_state_id uuid not null references workflow_states (id) on delete restrict,
    action text not null,
    actor_profile_id uuid references profiles (id) on delete set null,
    waiver_reason text,
    occurred_at timestamptz not null default now()
);

create index workflow_transition_log_subject_idx
    on workflow_transition_log (subject_type, subject_id, occurred_at desc);

comment on table workflow_transition_log is
    'Append-only, attributed. Course approvals previously recorded that a version was approved but not who approved it, from what, or when — the wrong way round for a platform selling accreditation. Deliberately NOT hash-chained: that machinery exists in esign_events because a signature must survive a challenge from a counterparty, and an internal approval trail needs to be append-only and attributed, not tamper-evident to the same standard.';

create or replace function workflow_log_is_append_only()
returns trigger
language plpgsql
as $$
begin
    raise exception 'workflow_transition_log is append-only: a % is refused. An approval that happened cannot be made not to have happened.', lower(tg_op);
end $$;

create trigger workflow_transition_log_no_update
    before update or delete on workflow_transition_log
    for each row execute function workflow_log_is_append_only();

-- ---------------------------------------------------------------------------
-- Checklist results become polymorphic
-- ---------------------------------------------------------------------------
--
-- The table is empty (zero rows) and unwired, so this is free. course_version_id
-- is kept and made nullable rather than dropped, because a column dropped in
-- the same migration that adds its replacement leaves no way to tell a
-- never-used write path from a broken one.

alter table workflow_checklist_results
    alter column course_version_id drop not null;

alter table workflow_checklist_results
    add column subject_type workflow_subject_type,
    add column subject_id uuid,
    add column waived boolean not null default false,
    add column waiver_reason text;

alter table workflow_checklist_results
    add constraint workflow_checklist_results_one_addressing
        check (
            (course_version_id is not null and subject_type is null and subject_id is null)
            or (course_version_id is null and subject_type is not null and subject_id is not null)
        ),
    -- Waivers stay possible and must carry a reason, following
    -- stage_gates.allow_waiver. A check that cannot be waived is a check that
    -- gets disabled.
    add constraint workflow_checklist_results_waiver_reason
        check ((waived = false) or (waiver_reason is not null and length(btrim(waiver_reason)) > 0));

create index workflow_checklist_results_subject_idx
    on workflow_checklist_results (subject_type, subject_id);

comment on column workflow_checklist_results.course_version_id is
    'DEPRECATED by migration 323. Use (subject_type, subject_id). Dropped once nothing writes it.';

-- ---------------------------------------------------------------------------
-- Tenant isolation
-- ---------------------------------------------------------------------------
--
-- subject_id points at a row in another table, so a foreign key cannot express
-- "and it must belong to the same organisation as the workflow". A trigger can.
-- Same shape as esign_line_item_tenant_guard() from migration 281.

create or replace function workflow_subject_org(p_subject_type workflow_subject_type, p_subject_id uuid)
returns uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
    select case p_subject_type
        when 'course_version' then (
            select c.owner_org_id
            from course_versions cv
            join courses c on c.id = cv.course_id
            where cv.id = p_subject_id
        )
        when 'esign_document' then (
            select d.owning_organization_id
            from esign_documents d
            where d.id = p_subject_id
        )
    end
$$;

comment on function workflow_subject_org(workflow_subject_type, uuid) is
    'The organisation a workflow subject belongs to. One place to extend when a third subject type is added, so the guard and the policies never disagree about who owns what.';

create or replace function workflow_subject_tenant_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_workflow_org uuid;
    v_workflow_subject workflow_subject_type;
    v_subject_org uuid;
begin
    select w.owning_organization_id, w.subject_type
    into v_workflow_org, v_workflow_subject
    from workflow_versions v
    join workflows w on w.id = v.workflow_id
    where v.id = new.workflow_version_id;

    if v_workflow_subject is distinct from new.subject_type then
        raise exception
            'WF-SUBJ-001: this workflow governs % and was handed a %. A workflow cannot be pointed at a subject of a different type.',
            v_workflow_subject, new.subject_type;
    end if;

    v_subject_org := workflow_subject_org(new.subject_type, new.subject_id);

    if v_subject_org is null then
        raise exception
            'WF-SUBJ-002: no % exists with id %. A workflow cannot record the position of something that is not there.',
            new.subject_type, new.subject_id;
    end if;

    -- A platform workflow (null organisation) governs every tenant's subjects;
    -- a tenant's own workflow governs only its own.
    if v_workflow_org is not null and v_workflow_org <> v_subject_org then
        raise exception
            'WF-SUBJ-003: this workflow belongs to organisation % and the subject belongs to %. Tenant isolation refuses the row.',
            v_workflow_org, v_subject_org;
    end if;

    return new;
end $$;

create trigger workflow_subject_states_tenant_guard
    before insert or update on workflow_subject_states
    for each row execute function workflow_subject_tenant_guard();

create trigger workflow_transition_log_tenant_guard
    before insert on workflow_transition_log
    for each row execute function workflow_subject_tenant_guard();

-- ---------------------------------------------------------------------------
-- Row-level security
-- ---------------------------------------------------------------------------

alter table workflows enable row level security;
alter table workflow_versions enable row level security;
alter table workflow_subject_states enable row level security;
alter table workflow_transition_log enable row level security;

-- Reading a definition is harmless and the application needs it on every page
-- that draws a status. Writing one is not: it changes who may approve what.
create policy workflows_read on workflows
    for select to authenticated
    using (auth.uid() is not null);

create policy workflows_manage on workflows
    for all to authenticated
    using (
        case
            when owning_organization_id is null then auth_role() = 'bespokelms_owner'::app_role
            else is_admin() and owning_organization_id in (select org_and_descendants(auth_org_id()))
        end
    )
    with check (
        case
            when owning_organization_id is null then auth_role() = 'bespokelms_owner'::app_role
            else is_admin() and owning_organization_id in (select org_and_descendants(auth_org_id()))
        end
    );

create policy workflow_versions_read on workflow_versions
    for select to authenticated
    using (auth.uid() is not null);

create policy workflow_versions_manage on workflow_versions
    for all to authenticated
    using (exists (
        select 1 from workflows w
        where w.id = workflow_versions.workflow_id
          and case
              when w.owning_organization_id is null then auth_role() = 'bespokelms_owner'::app_role
              else is_admin() and w.owning_organization_id in (select org_and_descendants(auth_org_id()))
          end
    ))
    with check (exists (
        select 1 from workflows w
        where w.id = workflow_versions.workflow_id
          and case
              when w.owning_organization_id is null then auth_role() = 'bespokelms_owner'::app_role
              else is_admin() and w.owning_organization_id in (select org_and_descendants(auth_org_id()))
          end
    ));

-- Subject-scoped rows follow the subject, not the workflow: who may see that a
-- course version is in review is whoever may manage that course.
create or replace function workflow_subject_access(p_subject_type workflow_subject_type, p_subject_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
    select case p_subject_type
        when 'course_version' then can_manage_course(course_of_version(p_subject_id))
        when 'esign_document' then esign_org_access(
            (select d.owning_organization_id from esign_documents d where d.id = p_subject_id)
        )
        else false
    end
$$;

comment on function workflow_subject_access(workflow_subject_type, uuid) is
    'Whether the caller may see and move this subject through its workflow. Delegates to the access rule the subject already has rather than inventing a second one, so a change to course or e-sign permissions cannot be forgotten here.';

create policy workflow_subject_states_access on workflow_subject_states
    for all to authenticated
    using (workflow_subject_access(subject_type, subject_id))
    with check (workflow_subject_access(subject_type, subject_id));

create policy workflow_transition_log_read on workflow_transition_log
    for select to authenticated
    using (workflow_subject_access(subject_type, subject_id));

create policy workflow_transition_log_append on workflow_transition_log
    for insert to authenticated
    with check (workflow_subject_access(subject_type, subject_id));

-- workflow_checklist_results had a course-only policy. Replace it with one that
-- answers for either addressing form, or a proposal's results are invisible.
drop policy if exists wf_checkresults_manage on workflow_checklist_results;

create policy workflow_checklist_results_access on workflow_checklist_results
    for all to authenticated
    using (
        case
            when subject_id is not null then workflow_subject_access(subject_type, subject_id)
            else can_manage_course(course_of_version(course_version_id))
        end
    )
    with check (
        case
            when subject_id is not null then workflow_subject_access(subject_type, subject_id)
            else can_manage_course(course_of_version(course_version_id))
        end
    );

-- Postgres grants EXECUTE to PUBLIC by default, so revoking from anon and
-- authenticated by name does nothing. Revoke from public, then grant back only
-- where it is needed. (Learned the hard way in migration 288.)
revoke execute on function workflow_subject_org(workflow_subject_type, uuid) from public;
revoke execute on function workflow_subject_access(workflow_subject_type, uuid) from public;
revoke execute on function workflow_log_is_append_only() from public;
revoke execute on function workflow_subject_tenant_guard() from public;
grant execute on function workflow_subject_access(workflow_subject_type, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Drift: a workflow that cannot work is refused before anything is stuck in it
-- ---------------------------------------------------------------------------

create or replace view v_workflow_definition_drift
with (security_invoker = on) as
with version_states as (
    select v.id as version_id, w.key as workflow_key, v.version_no, v.state as version_state,
           s.id as state_id, s.key as state_key, s.is_initial, s.is_terminal
    from workflow_versions v
    join workflows w on w.id = v.workflow_id
    left join workflow_states s on s.version_id = v.id
)
-- No initial state: nothing can enter the workflow.
select vs.version_id, vs.workflow_key, vs.version_no, vs.version_state,
       null::uuid as state_id, 'error'::text as severity, 'WF-DEF-001'::text as code,
       'No state is marked initial, so nothing can enter this workflow.'::text as detail
from version_states vs
group by vs.version_id, vs.workflow_key, vs.version_no, vs.version_state
having count(*) filter (where vs.is_initial) = 0

union all

-- Two initial states: entry is ambiguous and whichever the query returns first
-- wins, which is not a decision anybody made.
select vs.version_id, vs.workflow_key, vs.version_no, vs.version_state,
       null::uuid, 'error', 'WF-DEF-002',
       'More than one state is marked initial, so where a subject starts depends on row order.'
from version_states vs
group by vs.version_id, vs.workflow_key, vs.version_no, vs.version_state
having count(*) filter (where vs.is_initial) > 1

union all

-- No terminal state: nothing can ever finish.
select vs.version_id, vs.workflow_key, vs.version_no, vs.version_state,
       null::uuid, 'warning', 'WF-DEF-003',
       'No state is marked terminal, so nothing in this workflow can ever be finished with.'
from version_states vs
group by vs.version_id, vs.workflow_key, vs.version_no, vs.version_state
having count(*) filter (where vs.is_terminal) = 0

union all

-- Unreachable state: not initial and nothing transitions into it.
select vs.version_id, vs.workflow_key, vs.version_no, vs.version_state,
       vs.state_id, 'error', 'WF-DEF-004',
       vs.state_key || ' is not initial and no transition leads to it, so no subject can ever be in it.'
from version_states vs
where vs.state_id is not null
  and not vs.is_initial
  and not exists (
      select 1 from workflow_transitions t
      where t.version_id = vs.version_id and t.to_state_id = vs.state_id
  )

union all

-- Dead end: not terminal and nothing leads out.
select vs.version_id, vs.workflow_key, vs.version_no, vs.version_state,
       vs.state_id, 'error', 'WF-DEF-005',
       vs.state_key || ' is not terminal and has no transition out, so a subject reaching it is stuck.'
from version_states vs
where vs.state_id is not null
  and not vs.is_terminal
  and not exists (
      select 1 from workflow_transitions t
      where t.version_id = vs.version_id and t.from_state_id = vs.state_id
  )

union all

-- A checklist item bound to a transition in a different version. Cross-version
-- binding is how an item silently stops blocking anything.
select i.version_id, w.key, v.version_no, v.state,
       null::uuid, 'error', 'WF-DEF-006',
       'A checklist item blocks a transition that belongs to a different workflow version, so it blocks nothing.'
from workflow_checklist_items i
join workflow_versions v on v.id = i.version_id
join workflows w on w.id = v.workflow_id
join workflow_transitions t on t.id = i.blocks_transition_id
where t.version_id <> i.version_id;

comment on view v_workflow_definition_drift is
    'Every way a workflow definition can be broken in a way that only shows up when something is stuck in it. security_invoker = on: a view defaults to its owner''s rights and would otherwise read straight past RLS.';

-- NOTE ON WHAT THIS VIEW CANNOT SEE, stated rather than left to be discovered:
-- an automatic checklist item names an evaluator that lives in a PHP registry,
-- and SQL cannot read a PHP array. A check_rule naming an evaluator that does
-- not exist is therefore invisible here and must be caught by a test. This is
-- the same blind spot the navigation route registry has, and pretending
-- otherwise here would be worse than saying so.

-- ---------------------------------------------------------------------------
-- STD-DB-006 — claimed in schema_change_log immediately after this migration
-- is applied, because the version string is assigned at apply time and a
-- guessed one would not reconcile against supabase_migrations.
-- ---------------------------------------------------------------------------
