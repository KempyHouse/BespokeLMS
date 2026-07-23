-- ===========================================================================
-- BespokeLMS — Schema migration 009 (Change management: minor vs major)
-- Target: Supabase / Postgres.  Depends on 001–008.
--
-- Classifies every edit to a published course as MINOR (spelling/asset fix, no
-- learner impact → a x.y bump) or MAJOR (contextual rewrite, e.g. new
-- legislation → a new major version + re-approval + optional re-certification).
-- Sits on the version model in 003 (semver + version_migration_policy) and the
-- editorial approval in 005; feeds the tracker's "Review Required" flow.
--
-- Separation of duties: the approver of a change cannot be the raiser
-- (approver_id <> raised_by) — the DB mirror of 005's "one writes, another
-- approves". Impact metrics support an assisted "suggest major" heuristic so a
-- heavy edit can't be quietly logged as minor to skip re-certification.
--
-- Additive + declarative. Validated on real Postgres 16 against 001–008.
-- ===========================================================================

-- ============================ ENUMS ========================================
create type change_classification as enum ('minor','major');
create type change_category       as enum ('typo','asset','factual_correction','legislative_update','restructure','other');
create type learner_impact        as enum ('none','resume_ok','force_recert');
create type change_status         as enum ('open','approved','published','rejected');

-- ========================= CHANGE RECORDS ==================================
create table change_records (
  id                uuid primary key default gen_random_uuid(),
  course_id         uuid not null references courses(id) on delete cascade,
  from_version_id   uuid references course_versions(id) on delete set null,  -- the published version being changed
  to_version_id     uuid references course_versions(id) on delete set null,  -- the new version (null until published)
  classification    change_classification not null,
  category          change_category not null default 'other',
  reason            text,
  summary           text,
  learner_impact    learner_impact not null default 'none',
  status            change_status not null default 'open',
  -- impact metrics (feed the "suggest major" heuristic; set by the editor)
  affected_slide_count int,
  total_slide_count    int,
  assessment_touched   boolean not null default false,
  raised_by         uuid references profiles(id),
  approved_by       uuid references profiles(id),
  created_at        timestamptz not null default now(),
  approved_at       timestamptz,
  published_at      timestamptz,
  -- separation of duties: the approver may not be the person who raised it
  constraint change_approver_distinct check (approved_by is null or approved_by <> raised_by),
  -- a major change must declare a non-trivial learner impact once approved
  constraint change_major_impact check (
    not (classification = 'major' and status in ('approved','published'))
    or learner_impact <> 'none'
  )
);
create index on change_records(course_id);
create index on change_records(status);
create index on change_records(to_version_id);

-- Effective edit ratio (share of slides touched) — a read helper the editor's
-- heuristic uses to SUGGEST 'major' when a change touches a lot of content or
-- any assessment. The author still declares; the approver confirms.
create or replace view v_change_impact as
select
  cr.id as change_id,
  cr.course_id,
  cr.classification,
  cr.category,
  cr.assessment_touched,
  cr.affected_slide_count,
  cr.total_slide_count,
  case
    when coalesce(cr.total_slide_count, 0) = 0 then null
    else round(cr.affected_slide_count::numeric / cr.total_slide_count, 3)
  end as edit_ratio,
  -- heuristic: suggest 'major' if assessment touched or > 25% of slides changed
  ( cr.assessment_touched
    or ( coalesce(cr.total_slide_count,0) > 0
         and cr.affected_slide_count::numeric / cr.total_slide_count > 0.25 ) ) as suggests_major
from change_records cr;

-- ========================= ROW-LEVEL SECURITY ==============================
alter table change_records enable row level security;

-- change records are editorial management data → visible to and managed by
-- whoever may manage the course (per 003's can_manage_course).
create policy change_records_read   on change_records for select using ( can_manage_course(course_id) );
create policy change_records_manage on change_records for all
  using ( can_manage_course(course_id) ) with check ( can_manage_course(course_id) );

-- ============================ GRANTS =======================================
grant select on change_records, v_change_impact to anon, authenticated;
grant insert, update, delete on change_records to authenticated;   -- gated by RLS

-- NOTE: on a MAJOR change being published, the app applies the course's
-- version_migration_policy (003): finish-then-switch (in-flight learners keep
-- their pinned version, new enrolments get the new one) or force_recert (reset
-- completion, re-notify enrolled learners + managers via the notifications
-- module, re-base certificate expiry). A MINOR change publishes in place with no
-- learner impact. The change record's timeline (created/approved/published) is
-- the auditable trail, complementing course_workflow_history (005).
