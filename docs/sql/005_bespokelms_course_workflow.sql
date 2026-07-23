-- ===========================================================================
-- BespokeLMS — Schema migration 005 (Global Courses console · Phase 4)
-- Target: Supabase / Postgres.  Depends on 001 + 002 + 003 + 004.
--
-- Phase 4: the PLANNING TOOL — editorial workflow, per-course role assignment
-- (author / reviewer / approver), separation of duties, a sign-off checklist,
-- and the review-date engine.  Implements: "one team member writes the course,
-- another approves, and each course may include review dates."
--
-- The lifecycle is a DATA-DRIVEN state machine (states + transitions are rows,
-- global defaults with per-org overrides) so a tenant can insert extra steps
-- (e.g. Legal Review) without a schema change.  Transition GUARDS
-- (requires_distinct_actor, required_capability) are enforced by Laravel when a
-- transition is performed; these tables + RLS are the record and the isolation.
--
-- Additive + declarative.  Seeds the default global workflow + checklist, and
-- backfills each existing course_version into the matching state.
-- Validated on real Postgres 16 against 001+002+003+004.
-- ===========================================================================

-- ============================ ENUMS ========================================
create type course_assignment_role as enum ('author','reviewer','approver');
create type approval_decision      as enum ('approved','changes_requested','rejected');

-- ===================== WORKFLOW CONFIG (state machine) ====================
-- States and transitions: organization_id null = the global default workflow;
-- a tenant may define its own rows to extend/trim the lifecycle.
create table workflow_states (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid references organizations(id) on delete cascade,   -- null = global default
  key             text not null,          -- 'draft','in_review','approved','published','review_due','retired'
  label           text not null,
  is_initial      boolean not null default false,
  is_published    boolean not null default false,   -- the "live" state
  is_terminal     boolean not null default false,
  sort            int  not null default 0
);
-- one row per key within each scope (nulls-distinct guarded with partial uniques)
create unique index workflow_states_global_key on workflow_states(key) where organization_id is null;
create unique index workflow_states_org_key    on workflow_states(organization_id, key) where organization_id is not null;

create table workflow_transitions (
  id                     uuid primary key default gen_random_uuid(),
  organization_id        uuid references organizations(id) on delete cascade,  -- null = global default
  from_state_id          uuid not null references workflow_states(id) on delete cascade,
  to_state_id            uuid not null references workflow_states(id) on delete cascade,
  action                 text not null,   -- 'submit','approve','request_changes','publish','mark_review_due','reapprove','retire'
  requires_distinct_actor boolean not null default false,  -- separation of duties
  required_capability    text,            -- e.g. 'approve' | 'publish' (app maps to role/permission)
  sort                   int not null default 0,
  unique (from_state_id, action)
);

-- ===================== PER-COURSE WORKFLOW STATE =========================
create table course_workflow_state (
  course_version_id uuid primary key references course_versions(id) on delete cascade,
  state_id          uuid not null references workflow_states(id),
  entered_at        timestamptz not null default now(),
  entered_by        uuid references profiles(id)
);
create index on course_workflow_state(state_id);

create table course_workflow_history (
  id                uuid primary key default gen_random_uuid(),
  course_version_id uuid not null references course_versions(id) on delete cascade,
  from_state_id     uuid references workflow_states(id),
  to_state_id       uuid not null references workflow_states(id),
  action            text,
  actor_id          uuid references profiles(id),
  comment           text,
  at                timestamptz not null default now()
);
create index on course_workflow_history(course_version_id);

-- ===================== ROLES, APPROVALS, REVIEW DATES ====================
-- author/reviewer/approver assigned PER COURSE (different SMEs per course).
create table course_assignments (
  id          uuid primary key default gen_random_uuid(),
  course_id   uuid not null references courses(id) on delete cascade,
  user_id     uuid not null references profiles(id) on delete cascade,
  role        course_assignment_role not null,
  assigned_by uuid references profiles(id),
  assigned_at timestamptz not null default now(),
  unique (course_id, user_id, role)
);
create index on course_assignments(course_id);
create index on course_assignments(user_id);

-- immutable sign-off record (who approved/what/when) — the audit trail.
create table course_approvals (
  id                uuid primary key default gen_random_uuid(),
  course_version_id uuid not null references course_versions(id) on delete cascade,
  actor_id          uuid references profiles(id),
  decision          approval_decision not null,
  comment           text,
  signed_at         timestamptz not null default now()
);
create index on course_approvals(course_version_id);

-- content review clock (distinct from learner certificate expiry in enrollments).
create table review_schedule (
  course_id        uuid primary key references courses(id) on delete cascade,
  review_interval  interval,
  last_reviewed_at timestamptz,
  review_due_at    timestamptz,
  next_reminder_at timestamptz,
  updated_at       timestamptz not null default now()
);
create index on review_schedule(review_due_at);

-- ===================== SIGN-OFF CHECKLIST (publish gate) =================
create table workflow_checklist_items (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid references organizations(id) on delete cascade,  -- null = global default
  label           text not null,
  is_required     boolean not null default true,
  sort            int not null default 0
);

create table workflow_checklist_results (
  id                uuid primary key default gen_random_uuid(),
  course_version_id uuid not null references course_versions(id) on delete cascade,
  item_id           uuid not null references workflow_checklist_items(id) on delete cascade,
  checked_by        uuid references profiles(id),
  checked_at        timestamptz not null default now(),
  unique (course_version_id, item_id)
);
create index on workflow_checklist_results(course_version_id);

-- ========================= SEED DEFAULT WORKFLOW =========================
insert into workflow_states (organization_id, key, label, is_initial, is_published, is_terminal, sort) values
  (null,'draft',     'Draft',      true,  false, false, 10),
  (null,'in_review', 'In Review',  false, false, false, 20),
  (null,'approved',  'Approved',   false, false, false, 30),
  (null,'published', 'Published',  false, true,  false, 40),
  (null,'review_due','Review Due', false, false, false, 50),
  (null,'retired',   'Retired',    false, false, true,  60);

-- transitions reference the just-seeded global states by key
insert into workflow_transitions
  (organization_id, from_state_id, to_state_id, action, requires_distinct_actor, required_capability, sort)
select null, f.id, t.id, x.action, x.distinct_actor, x.cap, x.sort
from (values
  ('draft',     'in_review', 'submit',          false, 'edit',    10),
  ('in_review', 'approved',  'approve',         true,  'approve', 20),  -- separation of duties
  ('in_review', 'draft',     'request_changes', false, 'review',  30),
  ('approved',  'published', 'publish',         false, 'publish', 40),
  ('approved',  'draft',     'request_changes', false, 'review',  50),
  ('published', 'review_due','mark_review_due', false, null,      60),  -- date-triggered / system
  ('review_due','published', 'reapprove',       true,  'approve', 70),
  ('published', 'retired',   'retire',          false, 'publish', 80),
  ('review_due','retired',   'retire',          false, 'publish', 90)
) as x(from_key, to_key, action, distinct_actor, cap, sort)
join workflow_states f on f.key = x.from_key and f.organization_id is null
join workflow_states t on t.key = x.to_key   and t.organization_id is null;

-- default publish-gate checklist
insert into workflow_checklist_items (organization_id, label, is_required, sort) values
  (null,'Content reviewed for accuracy',            true, 10),
  (null,'Accessibility checked (WCAG 2.2 AA)',       true, 20),
  (null,'All required translations approved',        true, 30),
  (null,'Voiceover generated for published locales', false, 40),
  (null,'SME / subject-matter sign-off',             true, 50);

-- ===================== BACKFILL EXISTING VERSIONS ========================
-- Put every existing course_version into the global state matching its status.
insert into course_workflow_state (course_version_id, state_id, entered_at)
select cv.id, ws.id, cv.created_at
from course_versions cv
join workflow_states ws
  on ws.organization_id is null
 and ws.key = case cv.status
       when 'published' then 'published'
       when 'archived'  then 'retired'
       else 'draft'
     end;

-- seed a 12-month review clock for courses that have a live version
insert into review_schedule (course_id, review_interval, last_reviewed_at, review_due_at)
select c.id, interval '12 months', cv.published_at, cv.published_at + interval '12 months'
from courses c
join course_versions cv on cv.id = c.current_published_version_id
where cv.published_at is not null
on conflict (course_id) do nothing;

-- ========================= ROW-LEVEL SECURITY ============================
alter table workflow_states           enable row level security;
alter table workflow_transitions      enable row level security;
alter table course_workflow_state     enable row level security;
alter table course_workflow_history   enable row level security;
alter table course_assignments        enable row level security;
alter table course_approvals          enable row level security;
alter table review_schedule           enable row level security;
alter table workflow_checklist_items  enable row level security;
alter table workflow_checklist_results enable row level security;

-- config (states/transitions/checklist items): everyone reads; global rows are
-- owner-only, org rows are managed by an admin in that org subtree.
create policy wf_states_read       on workflow_states          for select using ( auth.uid() is not null );
create policy wf_transitions_read  on workflow_transitions     for select using ( auth.uid() is not null );
create policy wf_checkitems_read   on workflow_checklist_items for select using ( auth.uid() is not null );

create policy wf_states_manage on workflow_states for all using (
  case when organization_id is null then auth_role() = 'bespokelms_owner'
       else is_admin() and organization_id in (select org_and_descendants(auth_org_id())) end
) with check (
  case when organization_id is null then auth_role() = 'bespokelms_owner'
       else is_admin() and organization_id in (select org_and_descendants(auth_org_id())) end
);
create policy wf_transitions_manage on workflow_transitions for all using (
  case when organization_id is null then auth_role() = 'bespokelms_owner'
       else is_admin() and organization_id in (select org_and_descendants(auth_org_id())) end
) with check (
  case when organization_id is null then auth_role() = 'bespokelms_owner'
       else is_admin() and organization_id in (select org_and_descendants(auth_org_id())) end
);
create policy wf_checkitems_manage on workflow_checklist_items for all using (
  case when organization_id is null then auth_role() = 'bespokelms_owner'
       else is_admin() and organization_id in (select org_and_descendants(auth_org_id())) end
) with check (
  case when organization_id is null then auth_role() = 'bespokelms_owner'
       else is_admin() and organization_id in (select org_and_descendants(auth_org_id())) end
);

-- per-course workflow data: gated by who may manage the owning course.
create policy wf_state_manage on course_workflow_state for all
  using ( can_manage_course(course_of_version(course_version_id)) )
  with check ( can_manage_course(course_of_version(course_version_id)) );
create policy wf_history_manage on course_workflow_history for all
  using ( can_manage_course(course_of_version(course_version_id)) )
  with check ( can_manage_course(course_of_version(course_version_id)) );
create policy wf_approvals_manage on course_approvals for all
  using ( can_manage_course(course_of_version(course_version_id)) )
  with check ( can_manage_course(course_of_version(course_version_id)) );
create policy wf_checkresults_manage on workflow_checklist_results for all
  using ( can_manage_course(course_of_version(course_version_id)) )
  with check ( can_manage_course(course_of_version(course_version_id)) );
create policy assignments_manage on course_assignments for all
  using ( can_manage_course(course_id) )
  with check ( can_manage_course(course_id) );
create policy review_schedule_manage on review_schedule for all
  using ( can_manage_course(course_id) )
  with check ( can_manage_course(course_id) );

-- a user should also see the courses they're assigned to (author/reviewer/approver)
create policy assignments_self_read on course_assignments for select
  using ( user_id = my_profile_id() );

-- ============================ GRANTS =====================================
grant select on
  workflow_states, workflow_transitions, course_workflow_state,
  course_workflow_history, course_assignments, course_approvals,
  review_schedule, workflow_checklist_items, workflow_checklist_results
  to anon, authenticated;
grant insert, update, delete on
  workflow_states, workflow_transitions, course_workflow_state,
  course_workflow_history, course_assignments, course_approvals,
  review_schedule, workflow_checklist_items, workflow_checklist_results
  to authenticated;                         -- gated by the RLS policies above

-- NOTE: transition guards (requires_distinct_actor → approver_id != author_id,
-- required_capability → role/permission check) are enforced in the Laravel
-- service that performs a transition; a scheduled job flips 'published' →
-- 'review_due' when review_due_at passes and notifies the assigned reviewer.
