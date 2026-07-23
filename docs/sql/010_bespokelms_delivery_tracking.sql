-- ===========================================================================
-- BespokeLMS — Schema migration 010 (Learner delivery & tracking)
-- Target: Supabase / Postgres.  Depends on 001–009.
--
-- The attempt/tracking layer that course delivery and the retake/retry policy
-- (007) assume: attempts per enrolment (SCORM/cmi5 registration), the SCORM CMI
-- data model per SCO (completion/score/bookmark/suspend_data), native slide
-- progress, imported SCORM package metadata, and an xAPI statement store.
-- Learner records are tenant-isolated via enrolment visibility (visible_profile_ids).
--
-- Additive + declarative. No backfill (no attempts exist yet). Validated on
-- real Postgres 16 against 001–009.
-- ===========================================================================

-- ============================ ENUMS ========================================
create type attempt_status  as enum ('in_progress','completed','passed','failed','abandoned');
create type scorm_standard  as enum ('scorm_12','scorm_2004','cmi5');
create type cmi_completion   as enum ('completed','incomplete','not_attempted','unknown');
create type cmi_success      as enum ('passed','failed','unknown');

-- ===================== IMPORTED SCORM PACKAGES =============================
-- A course_version flagged is_scorm (003) is backed by one package here.
create table scorm_packages (
  id                uuid primary key default gen_random_uuid(),
  course_version_id uuid not null references course_versions(id) on delete cascade,
  standard          scorm_standard not null default 'scorm_12',
  manifest_ref      text,                     -- imsmanifest.xml location
  launch_url        text,                     -- SCO entry (relative)
  storage_prefix    text,                     -- Supabase Storage path of the extracted tree
  original_zip_path text,
  content_hash      text,
  imported_by       uuid references profiles(id),
  imported_at       timestamptz not null default now()
);
create index on scorm_packages(course_version_id);

-- ============================ ATTEMPTS =====================================
-- One row per registration (also the cmi5 registration id). A learner may have
-- multiple attempts on an enrolment subject to the retake/retry policy (007).
create table course_attempts (
  id               uuid primary key default gen_random_uuid(),
  enrollment_id    uuid not null references enrollments(id) on delete cascade,
  attempt_no       int  not null default 1,
  registration_uuid uuid not null default gen_random_uuid(),
  status           attempt_status not null default 'in_progress',
  score_scaled     numeric,                   -- -1..1 normalised
  started_at       timestamptz not null default now(),
  completed_at     timestamptz,
  created_at       timestamptz not null default now(),
  unique (enrollment_id, attempt_no),
  unique (registration_uuid)
);
create index on course_attempts(enrollment_id);
create index on course_attempts(status);

-- ============ SCORM CMI DATA MODEL (per SCO, per attempt) ==================
create table scorm_tracking (
  id                uuid primary key default gen_random_uuid(),
  attempt_id        uuid not null references course_attempts(id) on delete cascade,
  sco_id            text not null default 'sco-0',
  completion_status cmi_completion not null default 'unknown',
  success_status    cmi_success    not null default 'unknown',
  score_raw         numeric,
  score_min         numeric,
  score_max         numeric,
  score_scaled      numeric,
  total_time        interval,
  location          text,                     -- bookmark (cmi.location / lesson_location)
  suspend_data      text,                     -- opaque resume blob
  entry             text,
  exit              text,
  updated_at        timestamptz not null default now(),
  unique (attempt_id, sco_id)
);
create index on scorm_tracking(attempt_id);

-- ================= NATIVE SLIDE PROGRESS (per attempt) ====================
create table native_progress (
  id           uuid primary key default gen_random_uuid(),
  attempt_id   uuid not null references course_attempts(id) on delete cascade,
  slide_id     uuid not null references slides(id) on delete cascade,
  engaged      boolean not null default false,
  view_seconds int not null default 0,
  points       numeric,
  completed_at timestamptz,
  updated_at   timestamptz not null default now(),
  unique (attempt_id, slide_id)
);
create index on native_progress(attempt_id);

-- ===================== xAPI / cmi5 STATEMENT STORE ========================
create table xapi_statements (
  id                uuid primary key default gen_random_uuid(),
  organization_id   uuid references organizations(id) on delete cascade,
  registration_uuid uuid,
  actor             jsonb,
  verb              text,
  object_id         text,
  result            jsonb not null default '{}'::jsonb,
  stored_at         timestamptz not null default now()
);
create index on xapi_statements(organization_id);
create index on xapi_statements(registration_uuid);

-- ===================== RBAC / VISIBILITY HELPERS ==========================
create or replace function enrollment_user_visible(eid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from enrollments e where e.id = eid and e.user_id in (select visible_profile_ids()));
$$;

create or replace function enrollment_is_own(eid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from enrollments e where e.id = eid and e.user_id = my_profile_id());
$$;

create or replace function enrollment_of_attempt(aid uuid)
returns uuid language sql stable security definer set search_path = public as $$
  select enrollment_id from course_attempts where id = aid;
$$;

-- ========================= ROW-LEVEL SECURITY ==============================
alter table scorm_packages   enable row level security;
alter table course_attempts  enable row level security;
alter table scorm_tracking   enable row level security;
alter table native_progress  enable row level security;
alter table xapi_statements  enable row level security;

-- packages: read if you can see the course; manage if you can manage it.
create policy packages_read   on scorm_packages for select using ( can_see_course(course_of_version(course_version_id)) );
create policy packages_manage on scorm_packages for all
  using ( can_manage_course(course_of_version(course_version_id)) )
  with check ( can_manage_course(course_of_version(course_version_id)) );

-- attempts/tracking/progress: a learner's own records + the people allowed to
-- see that learner (managers/admins via visible_profile_ids). Writes = own.
create policy attempts_read   on course_attempts for select using ( enrollment_user_visible(enrollment_id) );
create policy attempts_manage on course_attempts for all
  using ( enrollment_is_own(enrollment_id) ) with check ( enrollment_is_own(enrollment_id) );

create policy tracking_read   on scorm_tracking for select using ( enrollment_user_visible(enrollment_of_attempt(attempt_id)) );
create policy tracking_manage on scorm_tracking for all
  using ( enrollment_is_own(enrollment_of_attempt(attempt_id)) )
  with check ( enrollment_is_own(enrollment_of_attempt(attempt_id)) );

create policy progress_read   on native_progress for select using ( enrollment_user_visible(enrollment_of_attempt(attempt_id)) );
create policy progress_manage on native_progress for all
  using ( enrollment_is_own(enrollment_of_attempt(attempt_id)) )
  with check ( enrollment_is_own(enrollment_of_attempt(attempt_id)) );

-- xAPI store: analytics — admins within the org subtree read; authenticated
-- (the LRS/service path) may write (further constrained server-side).
create policy xapi_read on xapi_statements for select
  using ( is_admin() and (organization_id is null or organization_id in (select org_and_descendants(auth_org_id()))) );
create policy xapi_insert on xapi_statements for insert with check ( auth.uid() is not null );

-- ============================ GRANTS =======================================
grant select on scorm_packages, course_attempts, scorm_tracking, native_progress, xapi_statements
  to anon, authenticated;
grant insert, update, delete on
  scorm_packages, course_attempts, scorm_tracking, native_progress, xapi_statements
  to authenticated;
grant execute on function
  enrollment_user_visible(uuid), enrollment_is_own(uuid), enrollment_of_attempt(uuid)
  to anon, authenticated;

-- NOTE: privileged writes (the SCORM run-time persisting CMI values, the LRS
-- storing xAPI) run server-side with the service-role key. Effective retake/
-- retry limits come from v_course_effective_pricing (007): the app checks the
-- attempt count against assessment_retry_limit / retake_after_pass before
-- allowing a new attempt. Learner progress is tenant-isolated via enrolment
-- visibility (visible_profile_ids), so no tenant can read another's records.
